/* Canonical Stark-field arithmetic on felt codes, shared by the felt stubs
   and the native CPU kernel so both inline the same load/store/add/sub/mul.

   Values cross the OCaml boundary as "codes" (untagged OCaml ints):
     0                 empty cell
     (v << 2) | 1      small felt v, |v| < 2^59, representing v mod p
     ...      | 2      relocatable (never seen here)
     (i << 2) | 3      big felt stored canonically at slot i of the pool
   The pool is a fixed, lazily committed char Bigarray holding 4 little-endian
   u64 limbs per slot; it never moves. Every big felt is canonical (< p) and
   never representable as a small felt, so equality of codes with tag 1 is
   integer equality. */
#ifndef CVM_FIELD_H
#define CVM_FIELD_H
#include <stdint.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

typedef uint64_t u64;
typedef unsigned __int128 u128;
typedef int64_t i64;

static const u64 P[4] = {1, 0, 0, 0x0800000000000011ULL};
#define SMALL_BOUND ((i64)1 << 59)

/* ---------- canonical (non-Montgomery) limb arithmetic ---------- */

static inline int geq_p(const u64 a[4]) {
  if (a[3] != P[3]) return a[3] > P[3];
  if (a[2] != 0) return 1;
  if (a[1] != 0) return 1;
  return a[0] >= 1;
}

#define ALWAYS_INLINE static inline __attribute__((always_inline))
/* Add with carry and subtract with borrow: the builtins where available
   (clang, GCC >= 14), otherwise portable 128-bit sums that compilers lower
   to adds/adcs or add/adc. Carries and borrows are 0 or 1. */
#if defined(__has_builtin)
#if __has_builtin(__builtin_addcll) && __has_builtin(__builtin_subcll)
#define HAVE_ADDCLL 1
#endif
#endif
#ifdef HAVE_ADDCLL
#define ADC(r, a, b, cin, cout) r = __builtin_addcll(a, b, cin, &cout)
#define SBB(r, a, b, bin, bout) r = __builtin_subcll(a, b, bin, &bout)
#else
static inline unsigned long long adc64(unsigned long long a, unsigned long long b,
                                       unsigned long long cin, unsigned long long *cout) {
  u128 s = (u128)a + b + cin;
  *cout = (unsigned long long)(s >> 64);
  return (unsigned long long)s;
}
static inline unsigned long long sbb64(unsigned long long a, unsigned long long b,
                                       unsigned long long bin, unsigned long long *bout) {
  u128 d = (u128)a - b - bin;
  *bout = (unsigned long long)(d >> 127);
  return (unsigned long long)d;
}
#define ADC(r, a, b, cin, cout) r = adc64(a, b, cin, &cout)
#define SBB(r, a, b, bin, bout) r = sbb64(a, b, bin, &bout)
#endif

static inline u64 sub4(u64 r[4], const u64 a[4], const u64 b[4]) {
  unsigned long long c;
  SBB(r[0], a[0], b[0], 0, c); SBB(r[1], a[1], b[1], c, c);
  SBB(r[2], a[2], b[2], c, c); SBB(r[3], a[3], b[3], c, c);
  return c;
}

static inline u64 add4(u64 r[4], const u64 a[4], const u64 b[4]) {
  unsigned long long c;
  ADC(r[0], a[0], b[0], 0, c); ADC(r[1], a[1], b[1], c, c);
  ADC(r[2], a[2], b[2], c, c); ADC(r[3], a[3], b[3], c, c);
  return c;
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

/* ---------- code <-> limbs ---------- */

#define SLOT(pool, i) ((u64 *)Caml_ba_data_val(pool) + ((size_t)(i) << 2))

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

/* Multiply a canonical field element by an immediate signed word. With
   B=2^64, p = P[3]*B^3 + 1. Divide the top two limbs by P[3], then
   subtract the quotient from the low limbs. The intermediate is already
   below p, or negative by at most one word. */
static inline void fmul_word(u64 r[4], const u64 x[4], i64 word) {
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

/* op: 0 add, 1 sub, 2 mul */
static inline intnat arith(value pool, intnat op, intnat a, intnat b, intnat dst) {
  u64 x[4], y[4], r[4];
  if (op == 2 && ((a & 3) == 1 || (b & 3) == 1)) {
    if ((a & 3) != 1) { intnat tmp = a; a = b; b = tmp; }
    load(pool, b, y);
    fmul_word(r, y, a >> 2);
    return store(pool, r, dst);
  }
  load(pool, a, x);
  load(pool, b, y);
  if (op == 0) fadd(r, x, y);
  else if (op == 1) fsub(r, x, y);
  else fmul(r, x, y);
  return store(pool, r, dst);
}

/* Limb of a bitwise builtin output: op 0 and, 1 xor, 2 or. */
static inline u64 bit_op(intnat op, u64 x, u64 y) {
  return op == 0 ? x & y : op == 1 ? x ^ y : x | y;
}

/* Bitwise builtin output of two felt codes; 0 when an input is at least
   2^251. Nonnegative small inputs stay immediate, and a result equal to an
   input reuses its code, so only a new big value takes the slot [dst]. */
static inline intnat bitwise(value pool, intnat op, intnat a, intnat b, intnat dst) {
  if ((a & 3) == 1 && (b & 3) == 1 && (a | b) >= 0) return bit_op(op, a, b) | 1;
  u64 x[4], y[4], r[4];
  load(pool, a, x);
  load(pool, b, y);
  if ((x[3] | y[3]) >> 59) return 0;
  for (int i = 0; i < 4; i++) r[i] = bit_op(op, x[i], y[i]);
  if (eq4(r, x)) return a;
  if (eq4(r, y)) return b;
  return store(pool, r, dst);
}
#endif
