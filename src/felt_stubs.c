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

static inline void mont_mul(u64 r[4], const u64 a[4], const u64 b[4]) {
  /* 512-bit product, then four reduction rounds exploiting p = 1 + P3*2^192:
     adding m*p with m = -t[i] clears limb i (carry = t[i] != 0) and adds
     m*P3 at limb i+3 - one multiplication per round. */
  u64 t0, t1, t2, t3, t4, t5, t6, t7, t8;
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
  t8 = 0;
  const u64 P3 = 0x0800000000000011ULL;
#define RED(x0, x1, x2, x3, x4, x5, x6, x7, x8)                       \
  { u64 m = -x0; u64 cy = x0 != 0;                                    \
    c = (u128)x1 + cy; x1 = (u64)c;                                   \
    c = (u128)x2 + (u64)(c >> 64); x2 = (u64)c;                       \
    c = (u128)m * P3 + x3 + (u64)(c >> 64); x3 = (u64)c;              \
    c = (u128)x4 + (u64)(c >> 64); x4 = (u64)c;                       \
    c = (u128)x5 + (u64)(c >> 64); x5 = (u64)c;                       \
    c = (u128)x6 + (u64)(c >> 64); x6 = (u64)c;                       \
    c = (u128)x7 + (u64)(c >> 64); x7 = (u64)c;                       \
    x8 += (u64)(c >> 64); }
  { u64 d9 = 0;
    RED(t0, t1, t2, t3, t4, t5, t6, t7, t8)
    RED(t1, t2, t3, t4, t5, t6, t7, t8, d9)
    { u64 d10 = 0; RED(t2, t3, t4, t5, t6, t7, t8, d9, d10) (void)d10; }
    { u64 d11 = 0; RED(t3, t4, t5, t6, t7, t8, d9, d9, d11) (void)d11; }
  }
#undef RED
  u64 t[4] = {t4, t5, t6, t7}; /* t8 == 0: result < 2p < 2^256 */
  if (geq_p(t)) sub4(t, t, P);
  r[0] = t[0]; r[1] = t[1]; r[2] = t[2]; r[3] = t[3];
}

/* Montgomery squaring: 6 cross products doubled + 4 squares, then the same
   specialised reduction as mont_mul. */
static inline void mont_sqr(u64 r[4], const u64 a[4]) {
  u64 a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
  u64 t0, t1, t2, t3, t4, t5, t6, t7, t8 = 0;
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
  const u64 P3 = 0x0800000000000011ULL;
#define RED(x0, x1, x2, x3, x4, x5, x6, x7, x8)                       \
  { u64 m = -x0; u64 cy = x0 != 0;                                    \
    c = (u128)x1 + cy; x1 = (u64)c;                                   \
    c = (u128)x2 + (u64)(c >> 64); x2 = (u64)c;                       \
    c = (u128)m * P3 + x3 + (u64)(c >> 64); x3 = (u64)c;              \
    c = (u128)x4 + (u64)(c >> 64); x4 = (u64)c;                       \
    c = (u128)x5 + (u64)(c >> 64); x5 = (u64)c;                       \
    c = (u128)x6 + (u64)(c >> 64); x6 = (u64)c;                       \
    c = (u128)x7 + (u64)(c >> 64); x7 = (u64)c;                       \
    x8 += (u64)(c >> 64); }
  { u64 d9 = 0, d10 = 0, d11 = 0;
    RED(t0, t1, t2, t3, t4, t5, t6, t7, t8)
    RED(t1, t2, t3, t4, t5, t6, t7, t8, d9)
    RED(t2, t3, t4, t5, t6, t7, t8, d9, d10)
    RED(t3, t4, t5, t6, t7, t8, d9, d10, d11)
    (void)d11; }
#undef RED
  u64 t[4] = {t4, t5, t6, t7};
  if (geq_p(t)) sub4(t, t, P);
  r[0] = t[0]; r[1] = t[1]; r[2] = t[2]; r[3] = t[3];
}

static void to_mont(u64 r[4], const u64 a[4]) { mont_mul(r, a, R2); }
static void from_mont(u64 r[4], const u64 a[4]) {
  static const u64 one[4] = {1, 0, 0, 0};
  mont_mul(r, a, one);
}

/* canonical multiply: (a*b*R^-1)*R^2*R^-1 */
static inline void fmul(u64 r[4], const u64 a[4], const u64 b[4]) {
  u64 t[4];
  mont_mul(t, a, b);
  mont_mul(r, t, R2);
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
  if (x[3] == P[3] && x[2] == 0 && x[1] == 0) {
    /* p - x = 1 - x0 (mod 2^64) when x0 >= 1 */
    u64 neg = 1 - x[0];
    if (x[0] >= 1 && neg < (u64)SMALL_BOUND && neg != 0)
      return (intnat)((-(i64)neg) * 4 + 1);
  }
  memcpy(SLOT(pool, dst), x, 32);
  return (intnat)((dst << 2) | 3);
}

value cvm_init(value unit) { init_consts(); return Val_unit; }

/* op: 0 add, 1 sub, 2 mul, 3 div (returns 0 when b == 0) */
intnat cvm_binop(value pool, intnat op, intnat a, intnat b, intnat dst) {
  u64 x[4], y[4], r[4];
  load(pool, a, x);
  load(pool, b, y);
  switch (op) {
  case 0: fadd(r, x, y); break;
  case 1: fsub(r, x, y); break;
  case 2: fmul(r, x, y); break;
  default:
    if (is_zero(y)) return 0;
    finv(y, y);
    fmul(r, x, y);
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

/* Pedersen: H(a,b) = [shift + a_low*P0 + a_high*P1 + b_low*P2 + b_high*P3].x
   a_low = low 248 bits, a_high = top 4 bits. Tables use 4-bit windows. */
#define PW 62 /* windows for 248 bits */
static aff *ped_tab = 0; /* [4][PW][16] (index 0 unused) */
static aff ped_shift;

static void batch_to_aff(aff *out, jac *in, int n) {
  /* Montgomery's trick */
  static u64 (*acc)[4] = 0;
  static int cap = 0;
  if (cap < n) { acc = realloc(acc, sizeof(u64[4]) * n); cap = n; }
  u64 run[4];
  memcpy(run, ONE_M, 32);
  for (int k = 0; k < n; k++) { memcpy(acc[k], run, 32); mont_mul(run, run, in[k].z); }
  u64 inv[4];
  mont_inv(inv, run);
  for (int k = n - 1; k >= 0; k--) {
    u64 zi[4], zi2[4], zi3[4];
    mont_mul(zi, inv, acc[k]);
    mont_mul(inv, inv, in[k].z);
    mont_sqr(zi2, zi); mont_mul(zi3, zi2, zi);
    mont_mul(out[k].x, in[k].x, zi2);
    mont_mul(out[k].y, in[k].y, zi3);
  }
}


static void ped_init(void) {
  if (ped_tab) return;
  init_consts();
  const u64 *xs[4] = {PEDERSEN_P0_X, PEDERSEN_P1_X, PEDERSEN_P2_X, PEDERSEN_P3_X};
  const u64 *ys[4] = {PEDERSEN_P0_Y, PEDERSEN_P1_Y, PEDERSEN_P2_Y, PEDERSEN_P3_Y};
  to_mont(ped_shift.x, SHIFT_POINT_X);
  to_mont(ped_shift.y, SHIFT_POINT_Y);
  int n = 4 * PW * 16;
  aff *tab = calloc(n, sizeof(aff));
  jac *tmp = calloc(n, sizeof(jac));
  for (int pt = 0; pt < 4; pt++) {
    jac base;
    to_mont(base.x, xs[pt]); to_mont(base.y, ys[pt]); memcpy(base.z, ONE_M, 32);
    for (int w = 0; w < PW; w++) {
      jac *row = &tmp[(pt * PW + w) * 16];
      /* row[j] = j * base, base = 16^w * P */
      memset(&row[0], 0, sizeof(jac));
      row[1] = base;
      aff ba; jac_to_aff(&ba, &base);
      for (int j = 2; j < 16; j++) jac_add_aff(&row[j], &row[j - 1], &ba);
      for (int d = 0; d < 4; d++) jac_double(&base, &base);
    }
  }
  /* convert all except index-0 entries (z = 0) */
  for (int k = 0; k < n; k++)
    if (is_zero(tmp[k].z)) memcpy(tmp[k].z, ONE_M, 32);
  batch_to_aff(tab, tmp, n);
  free(tmp);
  ped_tab = tab;
}

static inline void ped_accum(jac *acc, int pt, const u64 s[4], int nwin) {
  for (int w = 0; w < nwin; w++) {
    int d = (s[w >> 4] >> ((w & 15) * 4)) & 15;
    if (d) jac_add_aff(acc, acc, &ped_tab[(pt * PW + w) * 16 + d]);
  }
}

static void pedersen(u64 out[4], const u64 a[4], const u64 b[4]) {
  ped_init();
  jac acc;
  memcpy(acc.x, ped_shift.x, 32); memcpy(acc.y, ped_shift.y, 32); memcpy(acc.z, ONE_M, 32);
  u64 alow[4] = {a[0], a[1], a[2], a[3] & 0x00ffffffffffffffULL};
  u64 ahigh[4] = {a[3] >> 56, 0, 0, 0};
  u64 blow[4] = {b[0], b[1], b[2], b[3] & 0x00ffffffffffffffULL};
  u64 bhigh[4] = {b[3] >> 56, 0, 0, 0};
  ped_accum(&acc, 0, alow, PW);
  ped_accum(&acc, 1, ahigh, 1);
  ped_accum(&acc, 2, blow, PW);
  ped_accum(&acc, 3, bhigh, 1);
  aff r;
  jac_to_aff(&r, &acc);
  from_mont(out, r.x);
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

static inline void mix(u64 s0[4], u64 s1[4], u64 s2[4]) {
  u64 t[4], d[4];
  madd(t, s0, s1); madd(t, t, s2);
  madd(d, s0, s0); madd(s0, t, d);
  madd(d, s1, s1); msub(s1, t, d);
  madd(d, s2, s2); madd(d, d, s2); msub(s2, t, d);
}

static void hades(u64 s0[4], u64 s1[4], u64 s2[4]) {
  poseidon_init();
  int k = 0;
  for (int r = 0; r < 4; r++, k += 3) {
    madd(s0, s0, PRC[k]); madd(s1, s1, PRC[k + 1]); madd(s2, s2, PRC[k + 2]);
    cube(s0); cube(s1); cube(s2);
    mix(s0, s1, s2);
  }
  for (int r = 0; r < 83; r++, k++) {
    madd(s2, s2, PRC[k]);
    cube(s2);
    mix(s0, s1, s2);
  }
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

static void jac_add(jac *r, const jac *p, const jac *q) {
  if (is_zero(p->z)) { *r = *q; return; }
  if (is_zero(q->z)) { *r = *p; return; }
  u64 z1z1[4], z2z2[4], u1[4], u2[4], s1[4], s2[4], h[4], i[4], j[4], rr[4], v[4], t[4];
  jac o;
  mont_sqr(z1z1, p->z); mont_sqr(z2z2, q->z);
  mont_mul(u1, p->x, z2z2); mont_mul(u2, q->x, z1z1);
  mont_mul(s1, p->y, q->z); mont_mul(s1, s1, z2z2);
  mont_mul(s2, q->y, p->z); mont_mul(s2, s2, z1z1);
  msub(h, u2, u1); msub(rr, s2, s1);
  if (is_zero(h)) {
    if (is_zero(rr)) { jac_double(r, p); return; }
    memset(r, 0, sizeof *r); return;
  }
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
  if (!aff_on_curve(px, py) || !aff_on_curve(qx, qy)) return 2;
  jac ps, dp;
  memcpy(ps.x, px, 32); memcpy(ps.y, py, 32); memcpy(ps.z, ONE_M, 32);
  memcpy(dp.x, qx, 32); memcpy(dp.y, qy, 32); memcpy(dp.z, ONE_M, 32);
  int bits = 0;
  for (int k = 3; k >= 0; k--) if (m[k]) { bits = k * 64 + 64 - __builtin_clzll(m[k]); break; }
  if (bits > 256) bits = 256;
  for (int b = 0; b < bits; b++) {
    /* projective x comparison as in cairo-vm (Jacobian: X1 Z2^2 == X2 Z1^2) */
    u64 a1[4], a2[4], z[4];
    mont_sqr(z, dp.z); mont_mul(a1, ps.x, z);
    mont_sqr(z, ps.z); mont_mul(a2, dp.x, z);
    if (eq4(a1, a2)) return 1;
    if ((m[b >> 6] >> (b & 63)) & 1) jac_add(&ps, &ps, &dp);
    jac_double(&dp, &dp);
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
#include <caml/fail.h>
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

/* trace: bigarray of (pc code, ap, fp) triples; table: OCaml int array of segment bases */
value cvm_write_trace(value path, value trace, value vlen, value table) {
  FILE *f = fopen(String_val(path), "wb");
  if (!f) caml_failwith("cannot open trace file");
  static char buf[1 << 22];
  setvbuf(f, NULL, _IONBF, 0);
  intnat *t = (intnat *)Caml_ba_data_val(trace);
  intnat n = Long_val(vlen);
  intnat base1 = Long_val(Field(table, 1));
  size_t pos = 0;
  for (intnat i = 0; i < n; i += 3) {
    intnat pc = t[i];
    u64 e[3];
    e[0] = (u64)(base1 + t[i + 1]);
    e[1] = (u64)(base1 + t[i + 2]);
    e[2] = (u64)(Long_val(Field(table, rel_seg(pc))) + rel_off(pc));
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
