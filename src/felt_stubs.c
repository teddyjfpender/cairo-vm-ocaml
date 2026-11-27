/* Stark-field kernel for the OCaml Cairo VM.

   Values cross the OCaml boundary as "codes" (untagged OCaml ints):
     0                 empty cell
     (v << 2) | 1      small felt v, |v| < 2^59, representing v mod p
     ...      | 2      relocatable (never seen here)
     (i << 2) | 3      big felt stored canonically at slot i of the pool
   The pool is an OCaml [bytes] holding 4 little-endian u64 limbs per slot.
   Every big felt is canonical (< p) and never representable as a small felt,
   so equality of codes with tag 1 is integer equality.

   All entry points are [@@noalloc] with untagged arguments: the pool cannot
   move while they run. */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <caml/mlvalues.h>
#include <caml/fail.h>
#include <caml/hash.h>

typedef uint64_t u64;
typedef unsigned __int128 u128;
typedef int64_t i64;

#include "constants.h"

static const u64 P[4] = {1, 0, 0, 0x0800000000000011ULL};
#define SMALL_BOUND ((i64)1 << 59)

/* ---------- canonical (non-Montgomery) limb arithmetic ---------- */

static inline int geq_p(const u64 a[4]) {
  if (a[3] != P[3]) return a[3] > P[3];
  if (a[2] != 0) return 1;
  if (a[1] != 0) return 1;
  return a[0] >= 1;
}

static inline u64 sub4(u64 r[4], const u64 a[4], const u64 b[4]) {
  u64 borrow = 0;
  for (int i = 0; i < 4; i++) {
    u128 d = (u128)a[i] - b[i] - borrow;
    r[i] = (u64)d;
    borrow = (u64)(d >> 64) & 1;
  }
  return borrow;
}

static inline u64 add4(u64 r[4], const u64 a[4], const u64 b[4]) {
  u128 c = 0;
  for (int i = 0; i < 4; i++) {
    c = (u128)a[i] + b[i] + (u64)(c >> 64);
    r[i] = (u64)c;
  }
  return (u64)(c >> 64);
}

static inline void fadd(u64 r[4], const u64 a[4], const u64 b[4]) {
  add4(r, a, b); /* a,b < p < 2^252: no carry out */
  if (geq_p(r)) sub4(r, r, P);
}

static inline void fsub(u64 r[4], const u64 a[4], const u64 b[4]) {
  if (sub4(r, a, b)) add4(r, r, P);
}

static inline int is_zero(const u64 a[4]) { return (a[0] | a[1] | a[2] | a[3]) == 0; }
static inline int eq4(const u64 a[4], const u64 b[4]) {
  return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
}

/* ---------- Montgomery arithmetic, R = 2^256. -p^{-1} mod 2^64 = -1 ---------- */

static u64 R2[4];   /* R^2 mod p */
static u64 ONE_M[4];/* R mod p   */

/* For T = high * R + low, REDC(T) = high + REDC(low) before
   the final conditional subtraction. Reduce only the low half in the four
   cancellation rounds, then add high once. Since p = 1 + P3 * 2^192,
   m = -x0 cancels the bottom word, carrying (x0 != 0) into x1. */
static inline void mont_reduce(u64 r[4], u64 x0, u64 x1, u64 x2, u64 x3,
                               u64 h0, u64 h1, u64 h2, u64 h3) {
  u128 c;
#define CANCEL(a, b, d, e) do {                                  \
    u64 m = -(a);                                                 \
    c = (u128)(b) + ((a) != 0); (b) = (u64)c;                    \
    c = (u128)(d) + (u64)(c >> 64); (d) = (u64)c;                \
    c = (u128)m * P[3] + (e) + (u64)(c >> 64);                    \
    (e) = (u64)c; (a) = (u64)(c >> 64);                          \
  } while (0)
  CANCEL(x0, x1, x2, x3);
  CANCEL(x1, x2, x3, x0);
  CANCEL(x2, x3, x0, x1);
  CANCEL(x3, x0, x1, x2);
#undef CANCEL
  const u64 low[4] = {x0, x1, x2, x3}, high[4] = {h0, h1, h2, h3};
  add4(r, low, high);
  /* T < p^2 and p < R, so the unreduced result is below 2p < R. */
  if (geq_p(r)) sub4(r, r, P);
}

static inline void mont_mul(u64 r[4], const u64 a[4], const u64 b[4]) {
  /* 512-bit product, then four reduction rounds exploiting p = 1 + P3*2^192:
     adding m*p with m = -t[i] clears limb i (carry = t[i] != 0) and adds
     m*P3 at limb i+3 - one multiplication per round. */
  u64 t0, t1, t2, t3, t4, t5, t6, t7;
  u128 c;
  u64 a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
#define ROW(bi, x0, x1, x2, x3, x4)                                   \
  c = (u128)a0 * (bi) + x0; x0 = (u64)c;                              \
  c = (u128)a1 * (bi) + x1 + (u64)(c >> 64); x1 = (u64)c;             \
  c = (u128)a2 * (bi) + x2 + (u64)(c >> 64); x2 = (u64)c;             \
  c = (u128)a3 * (bi) + x3 + (u64)(c >> 64); x3 = (u64)c;             \
  x4 = (u64)(c >> 64);
  t0 = t1 = t2 = t3 = 0;
  ROW(b[0], t0, t1, t2, t3, t4)
  ROW(b[1], t1, t2, t3, t4, t5)
  ROW(b[2], t2, t3, t4, t5, t6)
  ROW(b[3], t3, t4, t5, t6, t7)
#undef ROW
  mont_reduce(r, t0, t1, t2, t3, t4, t5, t6, t7);
}

/* Montgomery squaring: 6 cross products doubled + 4 squares, then the same
   specialised reduction as mont_mul. */
static inline void mont_sqr(u64 r[4], const u64 a[4]) {
  u64 a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
  u64 t0, t1, t2, t3, t4, t5, t6, t7;
  u128 c;
  c = (u128)a0 * a1; t1 = (u64)c;
  c = (u128)a0 * a2 + (u64)(c >> 64); t2 = (u64)c;
  c = (u128)a0 * a3 + (u64)(c >> 64); t3 = (u64)c; t4 = (u64)(c >> 64);
  c = (u128)a1 * a2 + t3; t3 = (u64)c;
  c = (u128)a1 * a3 + t4 + (u64)(c >> 64); t4 = (u64)c; t5 = (u64)(c >> 64);
  c = (u128)a2 * a3 + t5; t5 = (u64)c; t6 = (u64)(c >> 64);
  t7 = t6 >> 63;
  t6 = (t6 << 1) | (t5 >> 63);
  t5 = (t5 << 1) | (t4 >> 63);
  t4 = (t4 << 1) | (t3 >> 63);
  t3 = (t3 << 1) | (t2 >> 63);
  t2 = (t2 << 1) | (t1 >> 63);
  t1 = t1 << 1;
  c = (u128)a0 * a0; t0 = (u64)c;
  c = (u128)t1 + (u64)(c >> 64); t1 = (u64)c;
  u128 s1 = (u128)a1 * a1;
  c = (u128)t2 + (u64)s1 + (u64)(c >> 64); t2 = (u64)c;
  c = (u128)t3 + (u64)(s1 >> 64) + (u64)(c >> 64); t3 = (u64)c;
  u128 s2 = (u128)a2 * a2;
  c = (u128)t4 + (u64)s2 + (u64)(c >> 64); t4 = (u64)c;
  c = (u128)t5 + (u64)(s2 >> 64) + (u64)(c >> 64); t5 = (u64)c;
  u128 s3 = (u128)a3 * a3;
  c = (u128)t6 + (u64)s3 + (u64)(c >> 64); t6 = (u64)c;
  c = (u128)t7 + (u64)(s3 >> 64) + (u64)(c >> 64); t7 = (u64)c;
  mont_reduce(r, t0, t1, t2, t3, t4, t5, t6, t7);
}

static void to_mont(u64 r[4], const u64 a[4]) { mont_mul(r, a, R2); }
static void from_mont(u64 r[4], const u64 a[4]) {
  static const u64 one[4] = {1, 0, 0, 0};
  mont_mul(r, a, one);
}

/* Reduce a canonical product without entering Montgomery form.
   With B=2^64, 32p=B^4+544B^3+32. Fold the four high coefficients
   using B^4 = -544B^3-32 (mod p). The largest temporary fits in
   104 signed bits. Normalize carries, fold the carry above limb 3,
   and finish with the top-limb quotient estimate for p. */
static inline void fmul(u64 r[4], const u64 a[4], const u64 b[4]) {
  u64 t[8] = {0};
  for (int i = 0; i < 4; i++) {
    u128 carry = 0;
    for (int j = 0; j < 4; j++) {
      carry = (u128)a[i] * b[j] + t[i+j] + (u64)(carry >> 64);
      t[i+j] = (u64)carry;
    }
    t[i+4] = (u64)(carry >> 64);
  }

  typedef __int128 wide;
  wide h7 = t[7], h6 = (wide)t[6]-544*h7;
  wide h5 = (wide)t[5]-544*h6, h4 = (wide)t[4]-544*h5;
  wide x0 = (wide)t[0]-32*h4, x1 = (wide)t[1]-32*h5;
  wide x2 = (wide)t[2]-32*h6, x3 = (wide)t[3]-32*h7-544*h4;
  x1 += x0 >> 64; x2 += x1 >> 64; x3 += x2 >> 64;
  wide extra = x3 >> 64;
  x0 = (wide)(u64)x0 - 32*extra;
  x1 = (wide)(u64)x1 + (x0 >> 64);
  x2 = (wide)(u64)x2 + (x1 >> 64);
  x3 = (wide)(u64)x3 - 544*extra + (x2 >> 64);

  wide quotient = x3 >> 59;
  x0 = (wide)(u64)x0 - quotient;
  x1 = (wide)(u64)x1 + (x0 >> 64);
  x2 = (wide)(u64)x2 + (x1 >> 64);
  x3 = x3 - quotient*P[3] + (x2 >> 64);
  r[0] = (u64)x0; r[1] = (u64)x1; r[2] = (u64)x2; r[3] = (u64)x3;
  if (x3 < 0) add4(r, r, P);
  else if (geq_p(r)) sub4(r, r, P);
}

/* Inverse of a canonical value via GMP's mpz_invert (Lehmer/HGCD; ~5x faster
   than Fermat at 256 bits).  Variable time is fine: nothing here is secret. */
#include <gmp.h>
static void canon_inv(u64 r[4], const u64 a[4]) {
  static mpz_t P_z, R_z;
  static int init = 0;
  if (!init) {
    mpz_init(P_z); mpz_import(P_z, 4, -1, 8, 0, 0, P);
    mpz_init2(R_z, 320);
    init = 1;
  }
  mpz_t A;
  mpz_roinit_n(A, (const mp_limb_t *)a, 4);
  if (!mpz_invert(R_z, A, P_z)) { r[0] = r[1] = r[2] = r[3] = 0; return; }
  size_t n = mpz_size(R_z);
  for (int i = 0; i < 4; i++) r[i] = (size_t)i < n ? mpz_getlimbn(R_z, i) : 0;
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

/* ---------- code <-> limbs ---------- */

#define SLOT(pool, i) ((u64 *)(Bytes_val(pool) + ((size_t)(i) << 5)))

static inline void load(value pool, intnat code, u64 out[4]) {
  if ((code & 3) == 3) {
    memcpy(out, SLOT(pool, code >> 2), 32);
  } else {
    i64 v = (i64)code >> 2;
    if (v >= 0) {
      out[0] = (u64)v; out[1] = out[2] = out[3] = 0;
    } else {
      u64 n[4] = {(u64)(-v), 0, 0, 0};
      sub4(out, P, n);
    }
  }
}

/* Return the canonical code for x, storing it at [dst] when it is big. */
static inline intnat store(value pool, const u64 x[4], intnat dst) {
  if (x[1] == 0 && x[2] == 0 && x[3] == 0 && x[0] < (u64)SMALL_BOUND)
    return (intnat)(((i64)x[0] << 2) | 1);
  /* p = P3 * 2^192 + 1. For p-1 the low limbs are zero. For
     p-n, 2 <= n < SMALL_BOUND, the borrow propagates to limb 3. */
  if (x[3] == P[3] && (x[2] | x[1] | x[0]) == 0)
    return -3; /* small(-1) */
  if (x[3] == P[3] - 1 && x[2] == UINT64_MAX && x[1] == UINT64_MAX &&
      x[0] > (u64)1 - (u64)SMALL_BOUND) {
    u64 magnitude = 1 - x[0];
    return -(intnat)magnitude * 4 + 1;
  }
  memcpy(SLOT(pool, dst), x, 32);
  return (intnat)((dst << 2) | 3);
}

value cvm_init(value unit) { init_consts(); return Val_unit; }

/* Multiply a canonical field element by an immediate signed word. With
   B=2^64, p = P[3]*B^3 + 1. Divide the top two limbs by P[3], then
   subtract the quotient from the low limbs. The intermediate is already
   below p, or negative by at most one word. */
static void fmul_word(u64 r[4], const u64 x[4], i64 word) {
  u64 magnitude = word < 0 ? (u64)-word : (u64)word;
  u128 product = 0;
  for (int i = 0; i < 4; i++) {
    product = (u128)x[i] * magnitude + (u64)(product >> 64);
    r[i] = (u64)product;
  }
  u64 quotient = (u64)(product / P[3]);
  r[3] = (u64)(product - (u128)quotient * P[3]);
  u64 correction[4] = {quotient, 0, 0, 0};
  fsub(r, r, correction);
  if (word < 0 && !is_zero(r)) sub4(r, P, r);
}

/* op: 0 add, 1 sub, 2 mul, 3 div (returns 0 when b == 0) */
intnat cvm_binop(value pool, intnat op, intnat a, intnat b, intnat dst) {
  u64 x[4], y[4], r[4];
  if (op == 2 && ((a & 3) == 1 || (b & 3) == 1)) {
    if ((a & 3) != 1) { intnat tmp = a; a = b; b = tmp; }
    load(pool, b, y);
    fmul_word(r, y, a >> 2);
    return store(pool, r, dst);
  }
  load(pool, a, x);
  load(pool, b, y);
  switch (op) {
  case 0: fadd(r, x, y); break;
  case 1: fsub(r, x, y); break;
  case 2: fmul(r, x, y); break;
  default:
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
  }
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
  return store(pool, r, dst);
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
   12 for the first 4 full rounds, 1 per partial round, 12 for the last 4. */
static u64 PRC[107][4];
static int prc_init = 0;
static void poseidon_init(void) {
  if (prc_init) return;
  init_consts();
  for (int i = 0; i < 107; i++) to_mont(PRC[i], POSEIDON_ORC[i]);
  prc_init = 1;
}

static inline void cube(u64 x[4]) {
  u64 t[4];
  mont_sqr(t, x);
  mont_mul(x, t, x);
}

/* Reduce a linear combination smaller than 7p. Its top five bits
   estimate floor(x/p), with at most one unit of overestimation because
   p = 2^251 + 17*2^192 + 1. */
static inline void reduce_mix(u64 x[4]) {
  u64 q = x[3] >> 59;
  u64 multiple[4] = {q, 0, 0, q * P[3]};
  if (sub4(x, x, multiple)) add4(x, x, P);
}

static inline void mix(u64 s0[4], u64 s1[4], u64 s2[4]) {
  u64 sum[4], tmp[4];
  static const u64 two_p[4] = {2, 0, 0, 0x1000000000000022ULL};
  add4(sum, s0, s1); add4(sum, sum, s2);
  /* sum+2a, sum+p-2b, sum+2p-3c are nonnegative and fit in 256 bits. */
  add4(tmp, s0, s0); add4(s0, sum, tmp);
  add4(tmp, s1, s1); add4(s1, sum, P); sub4(s1, s1, tmp);
  add4(tmp, s2, s2); add4(tmp, tmp, s2);
  add4(s2, sum, two_p); sub4(s2, s2, tmp);
  reduce_mix(s0); reduce_mix(s1); reduce_mix(s2);
}

static void hades(u64 s0[4], u64 s1[4], u64 s2[4]) {
  poseidon_init();
  int k = 0;
  for (int r = 0; r < 4; r++, k += 3) {
    madd(s0, s0, PRC[k]); madd(s1, s1, PRC[k + 1]); madd(s2, s2, PRC[k + 2]);
    cube(s0); cube(s1); cube(s2);
    mix(s0, s1, s2);
  }
  /* During partial rounds only c is cubed. Track a and l=a+b.
     For t=(2a+c) mod p after the cube, the next (a,l,c) is
     (t+l, 2t, l+2p-2c). This maintains a<3p, l<2p and c<4p.
     Thus c+constant <5p. Even its square is below R*p (25p<R),
     so ordinary Montgomery reduction still returns a canonical result. */
  u64 sum[4], t[4], twice[4];
  static const u64 two_p[4] = {2, 0, 0, 0x1000000000000022ULL};
  madd(sum, s0, s1);
  for (int r = 0; r < 83; r++, k++) {
    add4(s2, s2, PRC[k]);
    cube(s2);
    add4(t, s0, s0); add4(t, t, s2);
    reduce_mix(t);
    add4(s0, t, sum);
    add4(twice, s2, s2); add4(s2, sum, two_p); sub4(s2, s2, twice);
    add4(sum, t, t);
  }
  reduce_mix(s0); reduce_mix(sum); reduce_mix(s2);
  msub(s1, sum, s0);
  for (int r = 0; r < 4; r++, k += 3) {
    madd(s0, s0, PRC[k]); madd(s1, s1, PRC[k + 1]); madd(s2, s2, PRC[k + 2]);
    cube(s0); cube(s1); cube(s2);
    mix(s0, s1, s2);
  }
}

/* inputs/outputs: pool slots in canonical form */
void cvm_poseidon(value pool, intnat i0, intnat o0) {
  u64 s[3][4];
  for (int k = 0; k < 3; k++) to_mont(s[k], SLOT(pool, i0 + k));
  hades(s[0], s[1], s[2]);
  for (int k = 0; k < 3; k++) from_mont(SLOT(pool, o0 + k), s[k]);
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
    if (pos + 24 > sizeof buf) { fwrite(buf, 1, pos, f); pos = 0; }
  }
  fwrite(buf, 1, pos, f);
  fclose(f);
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
      if (pos + 40 > sizeof buf) { fwrite(buf, 1, pos, f); pos = 0; }
    }
  }
  fwrite(buf, 1, pos, f);
  fclose(f);
  return Val_unit;
}
value cvm_write_memory_byte(value *argv, int argc) {
  return cvm_write_memory(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}
