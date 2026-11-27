/* Stark-field kernel for the OCaml Cairo VM. Code encoding, the pool layout
   and the canonical arithmetic shared with the CPU kernel are in field.h.

   All entry points are [@@noalloc] with untagged arguments. */
#include <stdlib.h>
#include <sys/mman.h>
#include <caml/fail.h>
#include <caml/hash.h>
#include "field.h"
#include "constants.h"

/* ---------- Montgomery arithmetic, R = 2^256. -p^{-1} mod 2^64 = -1 ---------- */

static u64 R2[4];   /* R^2 mod p */
static u64 ONE_M[4];/* R mod p   */

#define ALWAYS_INLINE static inline __attribute__((always_inline))
/* Add with carry: the builtin where available (clang, GCC >= 14), otherwise a
   portable 128-bit sum that compilers lower to adds/adcs or add/adc. */
#if defined(__has_builtin)
#if __has_builtin(__builtin_addcll)
#define HAVE_ADDCLL 1
#endif
#endif
#ifdef HAVE_ADDCLL
#define ADC(r, a, b, cin, cout) r = __builtin_addcll(a, b, cin, &cout)
#else
static inline unsigned long long adc64(unsigned long long a, unsigned long long b,
                                       unsigned long long cin, unsigned long long *cout) {
  u128 s = (u128)a + b + cin;
  *cout = (unsigned long long)(s >> 64);
  return (unsigned long long)s;
}
#define ADC(r, a, b, cin, cout) r = adc64(a, b, cin, &cout)
#endif

/* REDC(T) for T = high * R + low, without the final subtraction: the result
   is congruent to T/R and below high + p + 1. Since p^-1 = 1 - P3*2^192
   (mod R), m = q*2^192 - low with q = low0*P3 gives low + m*p = 0 (mod R);
   the borrow k of that subtraction is (low + m) / R, so
   (low + m*p) / R = k + (q + m*P3) / 2^64. */
ALWAYS_INLINE void redc(u64 r[4], u64 t0, u64 t1, u64 t2, u64 t3,
                        u64 t4, u64 t5, u64 t6, u64 t7) {
  u64 q = t0 * P[3];
  u128 d = (u128)0 - t0;               u64 m0 = (u64)d;
  d = (u128)0 - t1 - (u64)(d >> 127);  u64 m1 = (u64)d;
  d = (u128)0 - t2 - (u64)(d >> 127);  u64 m2 = (u64)d;
  d = (u128)q - t3 - (u64)(d >> 127);  u64 m3 = (u64)d;
  u64 k = (u64)(d >> 127);
  u128 c = (u128)m0 * P[3] + q;
  c = (u128)m1 * P[3] + (u64)(c >> 64) + t4 + k; r[0] = (u64)c;
  c = (u128)m2 * P[3] + (u64)(c >> 64) + t5;     r[1] = (u64)c;
  c = (u128)m3 * P[3] + (u64)(c >> 64) + t6;     r[2] = (u64)c;
  r[3] = (u64)(c >> 64) + t7;
}

/* r = a * b (5 limbs) */
ALWAYS_INLINE void mul_row(u64 r[5], const u64 a[4], u64 b) {
  u128 p0 = (u128)a[0] * b, p1 = (u128)a[1] * b, p2 = (u128)a[2] * b, p3 = (u128)a[3] * b;
  unsigned long long c;
  r[0] = (u64)p0;
  ADC(r[1], (u64)(p0 >> 64), (u64)p1, 0, c);
  ADC(r[2], (u64)(p1 >> 64), (u64)p2, c, c);
  ADC(r[3], (u64)(p2 >> 64), (u64)p3, c, c);
  r[4] = (u64)(p3 >> 64) + c;
}

/* Lazy Montgomery product: for a, b < 2^255 the result is congruent to
   a*b/R and below a*b/R + p + 1 < 2^255. The four rows are summed as a
   tree, which shortens the carry chains on the latency-bound Hades path. */
ALWAYS_INLINE void lazy_mul(u64 r[4], const u64 a[4], const u64 b[4]) {
  u64 x[5], y[5], z[5], w[5], s1, s2, s3, s4, s5, u1, u2, u3, u4, u5;
  u64 t2, t3, t4, t5, t6;
  unsigned long long c, e;
  mul_row(x, a, b[0]); mul_row(y, a, b[1]); mul_row(z, a, b[2]); mul_row(w, a, b[3]);
  ADC(s1, x[1], y[0], 0, c); ADC(s2, x[2], y[1], c, c); ADC(s3, x[3], y[2], c, c);
  ADC(s4, x[4], y[3], c, c); s5 = y[4] + c;
  ADC(u1, z[1], w[0], 0, e); ADC(u2, z[2], w[1], e, e); ADC(u3, z[3], w[2], e, e);
  ADC(u4, z[4], w[3], e, e); u5 = w[4] + e;
  ADC(t2, s2, z[0], 0, c); ADC(t3, s3, u1, c, c); ADC(t4, s4, u2, c, c);
  ADC(t5, s5, u3, c, c); ADC(t6, 0, u4, c, c);
  redc(r, x[0], s1, t2, t3, t4, t5, t6, u5 + c);
}

/* Lazy squaring, same bounds: doubled cross products plus the squares. */
ALWAYS_INLINE void lazy_sqr(u64 r[4], const u64 a[4]) {
  u128 p01 = (u128)a[0] * a[1], p02 = (u128)a[0] * a[2], p03 = (u128)a[0] * a[3];
  u128 p12 = (u128)a[1] * a[2], p13 = (u128)a[1] * a[3], p23 = (u128)a[2] * a[3];
  u128 q0 = (u128)a[0] * a[0], q1 = (u128)a[1] * a[1];
  u128 q2 = (u128)a[2] * a[2], q3 = (u128)a[3] * a[3];
  u64 x1 = (u64)p01, x2, x3, x4, x5, x6, x7, t1, t2, t3, t4, t5, t6;
  unsigned long long c;
  ADC(x2, (u64)(p01 >> 64), (u64)p02, 0, c);
  ADC(x3, (u64)(p02 >> 64), (u64)p03, c, c);
  ADC(x4, (u64)(p03 >> 64), (u64)p13, c, c);
  ADC(x5, (u64)(p13 >> 64), (u64)p23, c, c);
  x6 = (u64)(p23 >> 64) + c;
  ADC(x3, x3, (u64)p12, 0, c); ADC(x4, x4, (u64)(p12 >> 64), c, c);
  ADC(x5, x5, 0, c, c); x6 += c;
  x7 = x6 >> 63;
  x6 = (x6 << 1) | (x5 >> 63); x5 = (x5 << 1) | (x4 >> 63); x4 = (x4 << 1) | (x3 >> 63);
  x3 = (x3 << 1) | (x2 >> 63); x2 = (x2 << 1) | (x1 >> 63); x1 <<= 1;
  ADC(t1, x1, (u64)(q0 >> 64), 0, c); ADC(t2, x2, (u64)q1, c, c);
  ADC(t3, x3, (u64)(q1 >> 64), c, c); ADC(t4, x4, (u64)q2, c, c);
  ADC(t5, x5, (u64)(q2 >> 64), c, c); ADC(t6, x6, (u64)q3, c, c);
  redc(r, (u64)q0, t1, t2, t3, t4, t5, t6, x7 + (u64)(q3 >> 64) + c);
}

/* One subtraction canonicalises when a*b/R < p - 1: canonical inputs,
   or a Hades output below 2p times one in from_mont. */
static inline void mont_mul(u64 r[4], const u64 a[4], const u64 b[4]) {
  lazy_mul(r, a, b);
  if (geq_p(r)) sub4(r, r, P);
}

static inline void mont_sqr(u64 r[4], const u64 a[4]) {
  lazy_sqr(r, a);
  if (geq_p(r)) sub4(r, r, P);
}

static void to_mont(u64 r[4], const u64 a[4]) { mont_mul(r, a, R2); }
static void from_mont(u64 r[4], const u64 a[4]) {
  static const u64 one[4] = {1, 0, 0, 0};
  mont_mul(r, a, one);
}


/* Inverse of a canonical value via GMP's mpz_invert (Lehmer/HGCD; ~5x faster
   than Fermat at 256 bits).  Variable time is fine: nothing here is secret. */
#include <gmp.h>
/* r = a^-1 mod m for 256-bit a and m > 1; 0 when a is not invertible. */
static int invert_mod(u64 r[4], const u64 a[4], const u64 m[4]) {
  static mpz_t R_z;
  static int init = 0;
  if (!init) { mpz_init2(R_z, 320); init = 1; }
  mpz_t A, M;
  mpz_roinit_n(A, (const mp_limb_t *)a, 4);
  mpz_roinit_n(M, (const mp_limb_t *)m, 4);
  if (!mpz_invert(R_z, A, M)) return 0;
  size_t n = mpz_size(R_z);
  for (int i = 0; i < 4; i++) r[i] = (size_t)i < n ? mpz_getlimbn(R_z, i) : 0;
  return 1;
}
static void canon_inv(u64 r[4], const u64 a[4]) {
  if (!invert_mod(r, a, P)) r[0] = r[1] = r[2] = r[3] = 0;
}

/* Montgomery-domain inverse: (aR)^-1 R = from(aR)^-1 * R^2 * R^-1 ... computed as to_mont(inv(from_mont(x))). */
static void to_mont(u64 r[4], const u64 a[4]);
static void from_mont(u64 r[4], const u64 a[4]);
static void mont_inv(u64 r[4], const u64 a[4]) {
  u64 c[4], i[4];
  from_mont(c, a);
  canon_inv(i, c);
  to_mont(r, i);
}

static void finv(u64 r[4], const u64 a[4]) { canon_inv(r, a); }

static int initialized = 0;
static void init_consts(void) {
  if (initialized) return;
  /* R mod p by doubling 1 256 times; R2 by doubling 512 times. */
  u64 x[4] = {1, 0, 0, 0};
  for (int i = 0; i < 512; i++) {
    fadd(x, x, x);
    if (i == 255) memcpy(ONE_M, x, 32);
  }
  memcpy(R2, x, 32);
  initialized = 1;
}

value cvm_init(value unit) { init_consts(); return Val_unit; }

/* Reserve the pool: [slots] 32-byte slots of lazily committed zero pages
   that are never moved or freed. */
value cvm_pool_make(value slots) {
  size_t length = (size_t)Long_val(slots) << 5;
  void *p = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) caml_raise_out_of_memory();
  return caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1, p, (intnat)length);
}

/* op: 0 add, 1 sub, 2 mul, 3 div (returns 0 when b == 0) */
intnat cvm_binop(value pool, intnat op, intnat a, intnat b, intnat dst) {
  if (op < 3) return arith(pool, op, a, b, dst);
  u64 x[4], y[4], r[4];
  load(pool, a, x);
  load(pool, b, y);
  if (is_zero(y)) return 0;
  /* A zero key is initially invalid because divisors are nonzero.
     Store limbs, never a pool pointer or OCaml value. */
  static _Thread_local u64 last_divisor[4], inverse_mont[4];
  if (!eq4(last_divisor, y)) {
    u64 inverse[4];
    finv(inverse, y);
    to_mont(inverse_mont, inverse);
    memcpy(last_divisor, y, sizeof last_divisor);
  }
  mont_mul(r, x, inverse_mont);
  return store(pool, r, dst);
}
value cvm_binop_byte(value pool, value op, value a, value b, value dst) {
  return Val_long(cvm_binop(pool, Long_val(op), Long_val(a), Long_val(b), Long_val(dst)));
}

/* Materialize code into slot [dst] (canonical limbs). */
void cvm_load_slot(value pool, intnat code, intnat dst) {
  u64 x[4];
  load(pool, code, x);
  memcpy(SLOT(pool, dst), x, 32);
}
value cvm_load_slot_byte(value pool, value c, value d) {
  cvm_load_slot(pool, Long_val(c), Long_val(d));
  return Val_unit;
}

/* Code of a canonical little-endian magnitude of at most 32 bytes. */
intnat cvm_of_bits(value pool, value bits, intnat dst) {
  u64 x[4] = {0};
  memcpy(x, String_val(bits), caml_string_length(bits));
  return store(pool, x, dst);
}
value cvm_of_bits_byte(value pool, value bits, value dst) {
  return Val_long(cvm_of_bits(pool, bits, Long_val(dst)));
}

/* Canonicalize slot [src] into a code (big values copied to [dst]). */
intnat cvm_code_of_slot(value pool, intnat src, intnat dst) {
  u64 x[4];
  memcpy(x, SLOT(pool, src), 32);
  if (geq_p(x)) {
    /* reduce an arbitrary 256-bit value: at most 31 subtractions of p (2^256/p < 32) */
    while (geq_p(x) || 0) {
      sub4(x, x, P);
    }
  }
  return store(pool, x, dst);
}
value cvm_code_of_slot_byte(value pool, value s, value d) {
  return Val_long(cvm_code_of_slot(pool, Long_val(s), Long_val(d)));
}

intnat cvm_big_hash(value pool, intnat code) {
  const u64 *x = SLOT(pool, code >> 2);
  uint32_t h = 0;
  for (int i = 0; i < 4; i++) h = caml_hash_mix_int64(h, (int64_t)x[i]);
  return h & 0x3fffffff;
}
value cvm_big_hash_byte(value pool, value code) {
  return Val_long(cvm_big_hash(pool, Long_val(code)));
}

intnat cvm_big_eq(value pool, intnat a, intnat b) {
  return eq4(SLOT(pool, a >> 2), SLOT(pool, b >> 2));
}
value cvm_big_eq_byte(value pool, value a, value b) {
  return Val_bool(cvm_big_eq(pool, Long_val(a), Long_val(b)));
}

/* bitwise on slots: inputs must be < 2^251, returns 0 on violation, else code */
intnat cvm_bitwise(value pool, intnat op, intnat a, intnat b, intnat dst) {
  u64 x[4], y[4], r[4];
  load(pool, a, x);
  load(pool, b, y);
  if ((x[3] >> 59) || (y[3] >> 59)) return 0;
  for (int i = 0; i < 4; i++)
    r[i] = op == 0 ? (x[i] & y[i]) : op == 1 ? (x[i] ^ y[i]) : (x[i] | y[i]);
  if (eq4(r, x)) return a;
  if (eq4(r, y)) return b;
  return store(pool, r, dst);
}
/* Compare assigned bitwise outputs directly in canonical limbs. Missing
   outputs stay holes. Return false to request the detailed OCaml checks. */
value cvm_verify_bitwise(value pool, value segment, value size) {
  intnat end = Long_val(size);
  if (end < 0 || end > Caml_ba_array_val(segment)->dim[0]) return Val_false;
  intnat *cells = Caml_ba_data_val(segment);
  for (intnat i = 0; i + 2 < end; i += 5) {
    intnat a = cells[i], b = cells[i+1];
    if ((a && !(a & 1)) || (b && !(b & 1))) return Val_false;
    if (!a || !b) continue;
    u64 x[4], y[4], actual[4];
    load(pool, a, x); load(pool, b, y);
    if ((x[3] | y[3]) >> 59) return Val_false;
    for (int k = 0; k < 3 && i+2+k < end; ++k) {
      intnat out = cells[i+2+k];
      if (!out) continue;
      if (!(out & 1)) return Val_false;
      load(pool, out, actual);
      for (int limb = 0; limb < 4; ++limb) {
        u64 expected = k == 0 ? x[limb] & y[limb] :
                       k == 1 ? x[limb] ^ y[limb] : x[limb] | y[limb];
        if (actual[limb] != expected) return Val_false;
      }
    }
  }
  return Val_true;
}

value cvm_bitwise_byte(value pool, value op, value a, value b, value d) {
  return Val_long(cvm_bitwise(pool, Long_val(op), Long_val(a), Long_val(b), Long_val(d)));
}

/* bit-length of value (0 for zero) */
/* Copy the low or high part at a whole-limb boundary (64 or 128 bits). */
intnat cvm_split_part(value pool, intnat code, intnat two_limbs, intnat high, intnat dst) {
  size_t width = two_limbs ? 2 : 1;
  u64 x[4], part[4] = {0};
  load(pool, code, x);
  if (high)
    memcpy(part, x + width, (4 - width) * sizeof(u64));
  else
    memcpy(part, x, width * sizeof(u64));
  return store(pool, part, dst);
}
value cvm_split_part_byte(value pool, value code, value two_limbs, value high, value dst) {
  return Val_long(cvm_split_part(pool, Long_val(code), Long_val(two_limbs), Long_val(high), Long_val(dst)));
}

intnat cvm_bits(value pool, intnat a) {
  u64 x[4];
  load(pool, a, x);
  for (int i = 3; i >= 0; i--)
    if (x[i]) return i * 64 + 64 - __builtin_clzll(x[i]);
  return 0;
}
value cvm_bits_byte(value pool, value a) { return Val_long(cvm_bits(pool, Long_val(a))); }

/* compare canonical values: -1, 0, 1 */
intnat cvm_cmp(value pool, intnat a, intnat b) {
  u64 x[4], y[4];
  load(pool, a, x);
  load(pool, b, y);
  for (int i = 3; i >= 0; i--)
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}
value cvm_cmp_byte(value pool, value a, value b) { return Val_long(cvm_cmp(pool, Long_val(a), Long_val(b))); }

/* ---------- integers modulo the secp/ed25519 hint primes ----------
   Secp_field values and moduli are 32-byte little-endian buffers: values in
   [0, 2^256), moduli in (1, 2^256). GMP's mpn layer works on stack limbs. */
#define L(x) ((mp_limb_t *)(x))
#define BUF(b) ((u64 *)Bytes_val(b))

static mp_size_t used(const u64 *x, mp_size_t n) {
  while (n > 0 && !x[n - 1]) n--;
  return n;
}

/* q, r = x divmod m for x >= 0 of n <= 8 limbs (q has 8 limbs). */
static void divrem(u64 q[8], u64 r[4], const u64 *x, mp_size_t n, const u64 m[4]) {
  mp_size_t mn = used(m, 4);
  n = used(x, n);
  memset(q, 0, 64);
  memset(r, 0, 32);
  if (n < mn) memcpy(r, x, n * 8);
  else mpn_tdiv_qr(L(q), L(r), 0, L(x), n, L(m), mn);
}

/* r = floor residue of (neg ? -x : x) */
static void floor_mod(u64 r[4], const u64 *x, mp_size_t n, int neg, const u64 m[4]) {
  u64 q[8];
  divrem(q, r, x, n, m);
  if (neg && !is_zero(r)) mpn_sub_n(L(r), L(m), L(r), 4);
}

/* op: 0 a+b, 1 a-b, 2 a*b, 3 a/b (returns 0 when b is not invertible) */
intnat cvm_sf_op(value vm, intnat op, value va, value vb, value vr) {
  const u64 *m = BUF(vm), *a = BUF(va), *b = BUF(vb);
  u64 t[8] = {0}, inv[4];
  int neg = 0;
  switch (op) {
  case 0: t[4] = mpn_add_n(L(t), L(a), L(b), 4); break;
  case 1:
    neg = mpn_cmp(L(a), L(b), 4) < 0;
    mpn_sub_n(L(t), L(neg ? b : a), L(neg ? a : b), 4);
    break;
  case 2: mpn_mul_n(L(t), L(a), L(b), 4); break;
  default:
    if (!invert_mod(inv, b, m)) return 0;
    mpn_mul_n(L(t), L(a), L(inv), 4);
  }
  floor_mod(BUF(vr), t, 8, neg, m);
  return 1;
}
value cvm_sf_op_byte(value m, value op, value a, value b, value r) {
  return Val_long(cvm_sf_op(m, Long_val(op), a, b, r));
}

/* BigInt3 pack d0 + d1 2^86 + d2 2^172 of signed felt limbs (cairo-vm's
   signed_felt), divided by m: [vr] gets the floor remainder. Returns the
   quotient's code when the division is exact and |q| < p, else 0 (empty). */
intnat cvm_sf_pack(value pool, intnat d0, intnat d1, intnat d2, value vm, value vr, intnat dst) {
  const intnat d[3] = {d0, d1, d2};
  const u64 *m = BUF(vm);
  u64 acc[8] = {0}, q[8], *r = BUF(vr);
  for (int i = 0; i < 3; i++) {
    u64 x[4], n[4], t[8] = {0};
    load(pool, d[i], x);
    sub4(n, P, x);
    int neg = mpn_cmp(L(n), L(x), 4) < 0; /* x > (p-1)/2 */
    const u64 *mag = neg ? n : x;
    int w = 86 * i / 64, s = 86 * i % 64;
    for (int k = 0; k < 4; k++) {
      t[w + k] |= mag[k] << s;
      if (s) t[w + k + 1] |= mag[k] >> (64 - s);
    }
    (neg ? mpn_sub_n : mpn_add_n)(L(acc), L(acc), L(t), 8);
  }
  int neg = acc[7] >> 63;
  if (neg) mpn_neg(L(acc), L(acc), 8);
  divrem(q, r, acc, 8, m);
  int exact = is_zero(r);
  if (neg && !exact) mpn_sub_n(L(r), L(m), L(r), 4);
  if (!exact || used(q, 8) > 4 || geq_p(q)) return 0;
  if (neg && !is_zero(q)) sub4(q, P, q);
  return store(pool, q, dst);
}
value cvm_sf_pack_byte(value *argv, int argc) {
  (void)argc;
  return Val_long(cvm_sf_pack(argv[0], Long_val(argv[1]), Long_val(argv[2]), Long_val(argv[3]), argv[4], argv[5],
                              Long_val(argv[6])));
}

/* The 86-bit limb i (0..2) of a value, as a felt code. */
intnat cvm_sf_limb86(value pool, value va, intnat i, intnat dst) {
  const u64 *a = BUF(va);
  int w = 86 * i / 64, s = 86 * i % 64;
  u64 x[4] = {0};
  for (int k = 0; k < 2 && w + k < 4; k++) {
    x[k] = a[w + k] >> s;
    if (s && w + k + 1 < 4) x[k] |= a[w + k + 1] << (64 - s);
  }
  x[1] &= ((u64)1 << 22) - 1;
  return store(pool, x, dst);
}
value cvm_sf_limb86_byte(value pool, value a, value i, value dst) {
  return Val_long(cvm_sf_limb86(pool, a, Long_val(i), Long_val(dst)));
}

/* ---------- Stark curve (alpha = 1) in Montgomery Jacobian coordinates ---------- */

typedef struct { u64 x[4], y[4]; } aff;          /* Montgomery affine */
typedef struct { u64 x[4], y[4], z[4]; } jac;    /* z == 0 => infinity */

static inline void madd(u64 r[4], const u64 a[4], const u64 b[4]) { fadd(r, a, b); }
static inline void msub(u64 r[4], const u64 a[4], const u64 b[4]) { fsub(r, a, b); }

static void jac_double(jac *r, const jac *p) {
  if (is_zero(p->z)) { *r = *p; return; }
  /* a = 1: M = 3X^2 + Z^4 */
  u64 xx[4], yy[4], yyyy[4], zz[4], s[4], m[4], t[4], x3[4], y3[4], z3[4];
  mont_sqr(xx, p->x);
  mont_sqr(yy, p->y);
  mont_sqr(yyyy, yy);
  mont_sqr(zz, p->z);
  /* S = 4*X*YY */
  mont_mul(s, p->x, yy); madd(s, s, s); madd(s, s, s);
  /* M = 3XX + ZZ^2 */
  mont_sqr(t, zz);
  madd(m, xx, xx); madd(m, m, xx); madd(m, m, t);
  /* X3 = M^2 - 2S */
  mont_sqr(x3, m); msub(x3, x3, s); msub(x3, x3, s);
  /* Y3 = M(S - X3) - 8 YYYY */
  msub(t, s, x3); mont_mul(y3, m, t);
  madd(t, yyyy, yyyy); madd(t, t, t); madd(t, t, t); msub(y3, y3, t);
  /* Z3 = 2 Y Z */
  mont_mul(z3, p->y, p->z); madd(z3, z3, z3);
  memcpy(r->x, x3, 32); memcpy(r->y, y3, 32); memcpy(r->z, z3, 32);
}

/* r = p + q (q affine) */
static void jac_add_aff(jac *r, const jac *p, const aff *q) {
  if (is_zero(p->z)) {
    memcpy(r->x, q->x, 32); memcpy(r->y, q->y, 32); memcpy(r->z, ONE_M, 32);
    return;
  }
  u64 z1z1[4], u2[4], s2[4], h[4], hh[4], i[4], j[4], rr[4], v[4], t[4], x3[4], y3[4], z3[4];
  mont_sqr(z1z1, p->z);
  mont_mul(u2, q->x, z1z1);
  mont_mul(s2, q->y, p->z); mont_mul(s2, s2, z1z1);
  msub(h, u2, p->x);
  msub(rr, s2, p->y);
  if (is_zero(h)) {
    if (is_zero(rr)) { jac_double(r, p); return; }
    memset(r, 0, sizeof *r); return; /* infinity */
  }
  madd(rr, rr, rr);
  mont_sqr(hh, h);
  madd(i, hh, hh); madd(i, i, i);
  mont_mul(j, h, i);
  mont_mul(v, p->x, i);
  mont_sqr(x3, rr); msub(x3, x3, j); msub(x3, x3, v); msub(x3, x3, v);
  msub(t, v, x3); mont_mul(y3, rr, t);
  mont_mul(t, p->y, j); madd(t, t, t); msub(y3, y3, t);
  madd(z3, p->z, h); mont_sqr(z3, z3); msub(z3, z3, z1z1); msub(z3, z3, hh);
  memcpy(r->x, x3, 32); memcpy(r->y, y3, 32); memcpy(r->z, z3, 32);
}

static void jac_to_aff(aff *r, const jac *p) {
  u64 zi[4], zi2[4], zi3[4];
  mont_inv(zi, p->z);
  mont_sqr(zi2, zi);
  mont_mul(zi3, zi2, zi);
  mont_mul(r->x, p->x, zi2);
  mont_mul(r->y, p->y, zi3);
}

/* Fixed-base tables store nonzero multiples in Montgomery affine form. */
#include "pedersen_table.h"

static void ped_accum(jac *acc, const aff low[31][255], const aff high[15], const u64 s[4]) {
  for (int limb = 0; limb < 4; limb++) {
    u64 bits = s[limb];
    if (limb == 3) bits &= 0x00ffffffffffffffULL;
    for (int w = 8 * limb; bits; w++, bits >>= 8) {
      unsigned digit = bits & 255;
      if (digit) jac_add_aff(acc, acc, &low[w][digit - 1]);
    }
  }
  unsigned top = s[3] >> 56;
  if (top) jac_add_aff(acc, acc, &high[top - 1]);
}

static void pedersen(u64 out[4], const u64 a[4], const u64 b[4]) {
  /* Fixed namespaces frequently hash different keys under the same prefix.
     Keep only canonical coordinates, independent of any VM's felt pool. */
  static _Thread_local struct { u64 key[4]; jac point; int valid; } previous;
  struct pair_entry { u64 a[4], b[4], hash[4]; int valid; };
  static _Thread_local struct { struct pair_entry ways[4]; unsigned next; } pairs[32];
  u64 h = a[0] ^ (b[0] * UINT64_C(0xbf58476d1ce4e5b9)) ^ a[3] ^ b[3];
  unsigned index = (h ^ (h >> 32)) & 31;
  for (int way = 0; way < 4; ++way) {
    struct pair_entry *e = &pairs[index].ways[way];
    if (e->valid && eq4(e->a, a) && eq4(e->b, b)) {
      memcpy(out, e->hash, sizeof e->hash);
      return;
    }
  }
  struct pair_entry *entry = &pairs[index].ways[pairs[index].next++ & 3];
  jac acc;
  if (previous.valid && eq4(previous.key, a)) {
    acc = previous.point;
  } else {
    memcpy(acc.x, ped_shift.x, 32); memcpy(acc.y, ped_shift.y, 32); memcpy(acc.z, ONE_M, 32);
    ped_accum(&acc, ped_a, ped_a_high[0], a);
    memcpy(previous.key, a, 32);
    previous.point = acc;
    previous.valid = 1;
  }
  ped_accum(&acc, ped_b, ped_b_high[0], b);
  u64 zi[4], x[4];
  mont_inv(zi, acc.z);
  mont_sqr(zi, zi);
  mont_mul(x, acc.x, zi);
  from_mont(out, x);
  memcpy(entry->a, a, sizeof entry->a);
  memcpy(entry->b, b, sizeof entry->b);
  memcpy(entry->hash, out, sizeof entry->hash);
  entry->valid = 1;
}

value cvm_verify_pedersen(value pool, value segment, value size, value cache) {
  intnat n = Long_val(size);
  if (n < 0 || n > Caml_ba_array_val(segment)->dim[0]) return Val_false;
  const intnat *cells = Caml_ba_data_val(segment);
  for (intnat i=0; i+2<n; i+=3) {
    intnat a = cells[i], b = cells[i+1], out = cells[i+2];
    if ((a && !(a&1)) || (b && !(b&1))) return Val_false;
    if (!a || !b || !out) continue;
    if (!(out&1)) return Val_false;
    if ((uintnat)(i+2) < Wosize_val(cache)) {
      intnat verified = Long_val(Field(cache, i+2));
      if (verified) {
        if (verified != out && !((verified & out & 3) == 3 && cvm_big_eq(pool, verified, out)))
          return Val_false;
        continue;
      }
    }
    u64 x[4], y[4], expected[4], actual[4];
    load(pool, a, x); load(pool, b, y); load(pool, out, actual);
    pedersen(expected, x, y);
    if (!eq4(expected, actual)) return Val_false;
  }
  return Val_true;
}

intnat cvm_pedersen(value pool, intnat a, intnat b, intnat dst) {
  u64 x[4], y[4], r[4];
  load(pool, a, x);
  load(pool, b, y);
  pedersen(r, x, y);
  return store(pool, r, dst);
}
value cvm_pedersen_byte(value pool, value a, value b, value d) {
  return Val_long(cvm_pedersen(pool, Long_val(a), Long_val(b), Long_val(d)));
}

/* ---------- Poseidon (Hades, 8 full + 83 partial rounds) ---------- */
/* Optimized constants (lambdaworks / Appendix B of the Poseidon paper):
   12 for the first 4 full rounds, 1 per partial round, 12 for the last 4.
   The state stays lazily reduced (below a small multiple of p) and only
   the outputs are canonicalised. kp = k*p is a nonnegative offset. */
#define KP(k) {k, 0, 0, k * 0x0800000000000011ULL}
static const u64 P4[4] = KP(4), P6[4] = KP(6);
static u64 PRC[107][4];
static int prc_init = 0;
static void poseidon_init(void) {
  if (prc_init) return;
  init_consts();
  for (int i = 0; i < 107; i++) to_mont(PRC[i], POSEIDON_ORC[i]);
  /* Partial-round constants carry the 4p offset of the next c below. */
  for (int i = 12; i < 95; i++) add4(PRC[i], PRC[i], P4);
  prc_init = 1;
}

/* Congruent value in [0, 2^251 + p) for x < 2^256 - p: subtract
   (floor(x / 2^251) - 1) * p, which overestimates x / p by less than one. */
ALWAYS_INLINE void reduce_lazy(u64 x[4]) {
  typedef __int128 wide;
  wide s = 1 - (wide)(x[3] >> 59);
  wide d = (wide)x[0] + s;     x[0] = (u64)d;
  d = (wide)x[1] + (d >> 64);  x[1] = (u64)d;
  d = (wide)x[2] + (d >> 64);  x[2] = (u64)d;
  x[3] = (u64)((wide)x[3] + s * (wide)P[3] + (d >> 64));
}

/* Below 9p (R > 31.99p), the cube is below 2p. */
ALWAYS_INLINE void cube(u64 x[4]) {
  u64 t[4];
  lazy_sqr(t, x);
  lazy_mul(x, t, x);
}

/* Lanes below 2p stay below 3p with their constant and 2p once cubed, so
   the MDS mix t=s0+s1+s2, (t+2s0, t-2s1, t-3s2) needs offsets 4p and 6p. */
ALWAYS_INLINE void full_round(u64 s[3][4], const u64 rc[3][4]) {
  u64 sum[4], t[4];
  for (int i = 0; i < 3; i++) { add4(s[i], s[i], rc[i]); cube(s[i]); }
  add4(sum, s[0], s[1]); add4(sum, sum, s[2]);
  add4(t, s[0], s[0]); add4(s[0], sum, t);
  add4(t, s[1], s[1]); add4(s[1], sum, P4); sub4(s[1], s[1], t);
  add4(t, s[2], s[2]); add4(t, t, s[2]); add4(s[2], sum, P6); sub4(s[2], s[2], t);
  for (int i = 0; i < 3; i++) reduce_lazy(s[i]);
}

static void hades(u64 s[3][4]) {
  const u64 (*rc)[4] = (const u64 (*)[4])PRC;
  for (int r = 0; r < 4; r++, rc += 3) full_round(s, rc);
  /* Partial rounds cube only c = s2. Track a = s0 and l = s0 + s1: for
     t = 2a + c the next (a, l, c) is (t + l, 2t, l - 2c + constant).
     Invariants a < 6p, l < 4p, c < 9p; the cube of c is below 2p. */
  u64 *a = s[0], *c = s[2], l[4], t[4], twice[4];
  add4(l, a, s[1]);
  add4(c, c, rc[0]);
  for (int r = 0; r < 83; r++, rc++) {
    cube(c);
    add4(t, a, a); add4(t, t, c); reduce_lazy(t);
    add4(a, t, l);
    add4(l, l, r < 82 ? rc[1] : P4);
    add4(twice, c, c); sub4(c, l, twice);
    add4(l, t, t);
  }
  add4(s[1], l, P6); sub4(s[1], s[1], a);
  for (int i = 0; i < 3; i++) reduce_lazy(s[i]);
  for (int r = 0; r < 4; r++, rc += 3) full_round(s, rc);
}

/* inputs/outputs: pool slots in canonical form */
void cvm_poseidon(value pool, intnat i0, intnat o0) {
  /* Independent calls can revisit the same node of a Merkle tree. Keys
     and values own their limbs, so pool growth and VM lifetimes are irrelevant. */
  struct entry { u64 input[3][4], output[3][4]; int valid; };
  static _Thread_local struct { struct entry ways[4]; unsigned next; } recent[64];
  const u64 *input = SLOT(pool, i0);
  u64 h = input[0] ^ (input[4] * UINT64_C(0x9e3779b97f4a7c15)) ^
          (input[8] * UINT64_C(0xbf58476d1ce4e5b9)) ^ input[3] ^ input[7] ^ input[11];
  unsigned index = (h ^ (h >> 32)) & 63;
  for (int way = 0; way < 4; ++way) {
    struct entry *e = &recent[index].ways[way];
    if (e->valid && memcmp(e->input, input, sizeof e->input) == 0) {
      memcpy(SLOT(pool, o0), e->output, sizeof e->output);
      return;
    }
  }
  struct entry *e = &recent[index].ways[recent[index].next++ & 3];
  memcpy(e->input, input, sizeof e->input);
  u64 s[3][4];
  poseidon_init();
  for (int k = 0; k < 3; k++) to_mont(s[k], SLOT(pool, i0 + k));
  hades(s);
  for (int k = 0; k < 3; k++) from_mont(e->output[k], s[k]);
  e->valid = 1;
  memcpy(SLOT(pool, o0), e->output, sizeof e->output);
}
value cvm_poseidon_byte(value pool, value i, value o) {
  cvm_poseidon(pool, Long_val(i), Long_val(o));
  return Val_unit;
}

/* ---------- Keccak-f[1600] on 8 felts of 200 bits ---------- */
static const u64 KRC[24] = {
  0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
  0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
  0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
  0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
  0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
  0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
static const int KROT[25] = {0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14};
#define ROL(x, n) ((n) ? (((x) << (n)) | ((x) >> (64 - (n)))) : (x))
static void keccak_f(u64 A[25]) {
  for (int round = 0; round < 24; round++) {
    u64 C[5], D[5], B[25];
    for (int x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
    for (int x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ ROL(C[(x + 1) % 5], 1);
    for (int i = 0; i < 25; i++) A[i] ^= D[i % 5];
    for (int x = 0; x < 5; x++)
      for (int y = 0; y < 5; y++) {
        int i = x + 5 * y;
        B[y + 5 * ((2 * x + 3 * y) % 5)] = ROL(A[i], KROT[i]);
      }
    for (int x = 0; x < 5; x++)
      for (int y = 0; y < 5; y++)
        A[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y]);
    A[0] ^= KRC[round];
  }
}
void keccak_f1600_raw(u64 A[25]) { keccak_f(A); }

/* 8 input slots (canonical, each < 2^200 checked by caller) -> 8 output slots */
void cvm_keccak(value pool, intnat i0, intnat o0) {
  uint8_t bytes[200];
  for (int k = 0; k < 8; k++) memcpy(bytes + 25 * k, SLOT(pool, i0 + k), 25);
  u64 A[25];
  memcpy(A, bytes, 200);
  keccak_f(A);
  memcpy(bytes, A, 200);
  for (int k = 0; k < 8; k++) {
    u64 *o = SLOT(pool, o0 + k);
    memset(o, 0, 32);
    memcpy(o, bytes + 25 * k, 25);
  }
}
value cvm_keccak_byte(value pool, value i, value o) {
  cvm_keccak(pool, Long_val(i), Long_val(o));
  return Val_unit;
}

/* Raw keccak256 helper for hints: data in bytes, output 32 bytes. */
value cvm_keccak256(value input, value output) {
  const uint8_t *in = (const uint8_t *)Bytes_val(input);
  size_t len = caml_string_length(input);
  u64 A[25];
  memset(A, 0, sizeof A);
  const size_t rate = 136;
  uint8_t block[136];
  size_t off = 0;
  for (;;) {
    size_t n = len - off;
    if (n >= rate) {
      memcpy(block, in + off, rate);
    } else {
      memset(block, 0, rate);
      memcpy(block, in + off, n);
      block[n] ^= 0x01;
      block[rate - 1] ^= 0x80;
    }
    for (size_t i = 0; i < rate / 8; i++) {
      u64 w;
      memcpy(&w, block + 8 * i, 8);
      A[i] ^= w;
    }
    keccak_f(A);
    if (n < rate) break;
    off += rate;
  }
  memcpy(Bytes_val(output), A, 32);
  return Val_unit;
}
value cvm_keccak_f_bytes(value st) { /* 200-byte state in place */
  u64 A[25];
  memcpy(A, Bytes_val(st), 200);
  keccak_f(A);
  memcpy(Bytes_val(st), A, 200);
  return Val_unit;
}

/* Incremental Keccak-256 for snapshots of append-only Cairo word ranges.
   The state includes the XORed partial rate block. Finalization only
   permutes a copy, so a caller can continue absorbing after a snapshot. */
value cvm_keccak_absorb(value state, value vpos, value input) {
  const size_t rate = 136;
  if (caml_string_length(state) != 200 || (uintnat)Long_val(vpos) >= rate)
    caml_invalid_argument("keccak_absorb state");
  u64 lanes[25];
  memcpy(lanes, Bytes_val(state), sizeof lanes);
  uint8_t *bytes = (uint8_t *)lanes;
  const uint8_t *data = (const uint8_t *)Bytes_val(input);
  size_t length = caml_string_length(input), pos = Long_val(vpos);
  while (length) {
    size_t n = rate - pos;
    if (n > length) n = length;
    for (size_t i = 0; i < n; i++) bytes[pos+i] ^= data[i];
    length -= n;
    data += n;
    pos += n;
    if (pos == rate) { keccak_f(lanes); pos = 0; }
  }
  memcpy(Bytes_val(state), lanes, sizeof lanes);
  return Val_long(pos);
}

value cvm_keccak_snapshot(value state, value vpos, value output) {
  if (caml_string_length(state) != 200 || (uintnat)Long_val(vpos) >= 136 || caml_string_length(output) != 32)
    caml_invalid_argument("keccak_snapshot state");
  u64 lanes[25];
  memcpy(lanes, Bytes_val(state), sizeof lanes);
  uint8_t *bytes = (uint8_t *)lanes;
  bytes[Long_val(vpos)] ^= 0x01;
  bytes[135] ^= 0x80;
  keccak_f(lanes);
  memcpy(Bytes_val(output), lanes, 32);
  return Val_unit;
}

/* ---------- EC op builtin: R = P + m*Q (canonical affine, alpha = 1) ----------
   Slots: px py qx qy m at i0..i0+4; result rx ry to o0, o0+1.
   Returns 0 on success, 1 when P,Q x-coordinates collide during the ladder,
   2 when a point is not on the curve. Mirrors cairo-vm's ec_op_impl (affine,
   double-and-add from the low bit, height 256). */
static const u64 BETA_C[4] = {0xf4cdfcb99cee9e89ULL, 0x609ad26c15c915c1ULL, 0x150e596d72f7a8c5ULL, 0x06f21413efbe40deULL};

static int aff_on_curve(const u64 x[4], const u64 y[4]) { /* Montgomery inputs */
  u64 lhs[4], rhs[4], t[4], b[4];
  mont_sqr(lhs, y);
  mont_sqr(t, x); mont_mul(rhs, t, x);
  madd(rhs, rhs, x);
  to_mont(b, BETA_C);
  madd(rhs, rhs, b);
  return eq4(lhs, rhs);
}

/* Called only after the EC builtin's mandatory unequal-x check. */
static void ec_add(jac *r, const jac *p, const jac *q,
                   const u64 z1z1[4], const u64 z2z2[4],
                   const u64 u1[4], const u64 u2[4]) {
  u64 s1[4], s2[4], h[4], i[4], j[4], rr[4], v[4], t[4];
  jac o;
  mont_mul(s1, p->y, q->z); mont_mul(s1, s1, z2z2);
  mont_mul(s2, q->y, p->z); mont_mul(s2, s2, z1z1);
  msub(h, u2, u1); msub(rr, s2, s1);
  madd(i, h, h); mont_sqr(i, i);
  mont_mul(j, h, i);
  madd(rr, rr, rr);
  mont_mul(v, u1, i);
  mont_sqr(o.x, rr); msub(o.x, o.x, j); msub(o.x, o.x, v); msub(o.x, o.x, v);
  msub(t, v, o.x); mont_mul(o.y, rr, t);
  mont_mul(t, s1, j); madd(t, t, t); msub(o.y, o.y, t);
  madd(t, p->z, q->z); mont_sqr(t, t); msub(t, t, z1z1); msub(t, t, z2z2); mont_mul(o.z, t, h);
  *r = o;
}

intnat cvm_ec_op(value pool, intnat i0, intnat o0) {
  init_consts();
  u64 px[4], py[4], qx[4], qy[4], m[4];
  to_mont(px, SLOT(pool, i0)); to_mont(py, SLOT(pool, i0 + 1));
  to_mont(qx, SLOT(pool, i0 + 2)); to_mont(qy, SLOT(pool, i0 + 3));
  memcpy(m, SLOT(pool, i0 + 4), 32);
  /* Powers are deterministic functions of a validated Q. Keep one ladder
     per native thread; every call starts a fresh accumulator for its P. */
  static _Thread_local struct {
    jac power[256];
    u64 z_squared[256][4];
    int count;
  } ladder;
  if (!aff_on_curve(px, py)) return 2;
  if (!ladder.count || !eq4(qx, ladder.power[0].x) || !eq4(qy, ladder.power[0].y)) {
    if (!aff_on_curve(qx, qy)) return 2;
    memcpy(ladder.power[0].x, qx, 32); memcpy(ladder.power[0].y, qy, 32);
    memcpy(ladder.power[0].z, ONE_M, 32); memcpy(ladder.z_squared[0], ONE_M, 32);
    ladder.count = 1;
  }
  jac ps;
  u64 ps_z_squared[4];
  memcpy(ps.x, px, 32); memcpy(ps.y, py, 32); memcpy(ps.z, ONE_M, 32);
  memcpy(ps_z_squared, ONE_M, 32);
  int bits = 0;
  for (int k = 3; k >= 0; k--) if (m[k]) { bits = k * 64 + 64 - __builtin_clzll(m[k]); break; }
  for (int b = 0; b < bits; b++) {
    if (b == ladder.count) {
      jac_double(&ladder.power[b], &ladder.power[b-1]);
      mont_sqr(ladder.z_squared[b], ladder.power[b].z);
      ladder.count++;
    }
    const jac *q = &ladder.power[b];
    u64 u1[4], u2[4];
    mont_mul(u1, ps.x, ladder.z_squared[b]);
    mont_mul(u2, q->x, ps_z_squared);
    if (eq4(u1, u2)) return 1;
    if ((m[b >> 6] >> (b & 63)) & 1) {
      ec_add(&ps, &ps, q, ps_z_squared, ladder.z_squared[b], u1, u2);
      mont_sqr(ps_z_squared, ps.z);
    }
  }
  if (is_zero(ps.z)) return 3;
  aff r;
  jac_to_aff(&r, &ps);
  from_mont(SLOT(pool, o0), r.x);
  from_mont(SLOT(pool, o0 + 1), r.y);
  return 0;
}
value cvm_ec_op_byte(value pool, value i, value o) {
  return Val_long(cvm_ec_op(pool, Long_val(i), Long_val(o)));
}

/* Write the canonical 32-byte little-endian encoding of a felt code into buf[pos]. */
void cvm_put_code(value pool, intnat code, value buf, intnat pos) {
  u64 x[4];
  load(pool, code, x);
  memcpy(Bytes_val(buf) + pos, x, 32);
}
value cvm_put_code_byte(value pool, value c, value b, value p) {
  cvm_put_code(pool, Long_val(c), b, Long_val(p));
  return Val_unit;
}

/* Zero-initialized int Bigarray backed by calloc: large requests are served by
   lazily-zeroed pages, so untouched capacity costs no time or RSS. */
#include <caml/bigarray.h>
#include <caml/alloc.h>
#include <caml/memory.h>
value cvm_zalloc(value vn) {
  intnat n = Long_val(vn);
  if (n < 1) n = 1;
  void *p = calloc((size_t)n, sizeof(intnat));
  if (!p) caml_raise_out_of_memory();
  return caml_ba_alloc_dims(CAML_BA_CAML_INT | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 1, p, n);
}

/* ---------- binary trace / memory writers (cairo-vm format) ---------- */
#include <stdio.h>
#define OFF_MASK ((1LL << 40) - 1)
static inline intnat rel_seg(intnat c) { return c >> 42; }
static inline intnat rel_off(intnat c) { return (c >> 2) & OFF_MASK; }

static void write_chunk(FILE *f, const char *buf, size_t len) {
  if (fwrite(buf, 1, len, f) != len) {
    fclose(f);
    caml_failwith("cannot write Cairo artifact");
  }
}

/* Decode Vm.record_trace entries to ordinary relocated (ap, fp, pc) triples. */
value cvm_write_trace(value path, value trace, value vlen, value table) {
  FILE *f = fopen(String_val(path), "wb");
  if (!f) caml_failwith("cannot open trace file");
  static char buf[1 << 22];
  setvbuf(f, NULL, _IONBF, 0);
  intnat *t = (intnat *)Caml_ba_data_val(trace);
  intnat n = Long_val(vlen);
  intnat base1 = Long_val(Field(table, 1));
  size_t pos = 0;
  const u64 offset_mask = (1ULL << 23) - 1;
  const u64 base0 = Long_val(Field(table, 0));
  for (intnat i = 0; i < n;) {
    intnat word = t[i++];
    u64 e[3];
    if (word & 1) {
      u64 packed = (u64)word;
      e[0] = base1 + ((packed >> 24) & offset_mask);
      e[1] = base1 + ((packed >> 1) & offset_mask);
      e[2] = base0 + ((packed >> 47) & 0xffff);
    } else {
      intnat pc = word;
      e[0] = (u64)(base1 + t[i++]);
      e[1] = (u64)(base1 + t[i++]);
      e[2] = (u64)(Long_val(Field(table, rel_seg(pc))) + rel_off(pc));
    }
    memcpy(buf + pos, e, 24);
    pos += 24;
    if (pos + 24 > sizeof buf) { write_chunk(f, buf, pos); pos = 0; }
  }
  write_chunk(f, buf, pos);
  if (fclose(f) != 0) caml_failwith("cannot close Cairo artifact");
  return Val_unit;
}

/* memory: segs is an OCaml array of segment bigarrays, sizes an int array */
value cvm_write_memory(value path, value segs, value sizes, value table, value vnsegs, value pool) {
  FILE *f = fopen(String_val(path), "wb");
  if (!f) caml_failwith("cannot open memory file");
  setvbuf(f, NULL, _IONBF, 0);
  static char buf[40 * 100000];
  size_t pos = 0;
  intnat nsegs = Long_val(vnsegs);
  for (intnat s = 0; s < nsegs; s++) {
    intnat *a = (intnat *)Caml_ba_data_val(Field(segs, s));
    intnat n = Long_val(Field(sizes, s));
    u64 base = (u64)Long_val(Field(table, s));
    for (intnat off = 0; off < n; off++) {
      intnat v = a[off];
      if (v == 0) continue;
      u64 w[5] = {base + (u64)off, 0, 0, 0, 0};
      if ((v & 3) == 2) {
        intnat sg = rel_seg(v);
        if (sg < 0 || sg >= nsegs) { fclose(f); caml_failwith("cannot relocate value"); }
        w[1] = (u64)Long_val(Field(table, sg)) + (u64)rel_off(v);
      } else {
        load(pool, v, &w[1]);
      }
      memcpy(buf + pos, w, 40);
      pos += 40;
      if (pos + 40 > sizeof buf) { write_chunk(f, buf, pos); pos = 0; }
    }
  }
  write_chunk(f, buf, pos);
  if (fclose(f) != 0) caml_failwith("cannot close Cairo artifact");
  return Val_unit;
}
value cvm_write_memory_byte(value *argv, int argc) {
  return cvm_write_memory(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}
