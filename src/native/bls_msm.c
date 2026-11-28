/* Variable-time multiscalar multiplication on the public BLS12-381 monomial
   setup. Each coordinate has six little-endian GMP limbs. Intermediate group
   operations stay in Montgomery form until the single final inversion. */
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <gmp.h>
#include <caml/mlvalues.h>
#include <caml/fail.h>

typedef mp_limb_t fq[6];
typedef struct {
  fq x, y;
} affine;
typedef struct {
  fq x, y, z;
} point;

_Static_assert(GMP_NUMB_BITS == 64, "BLS12-381 requires 64-bit GMP limbs");
static const fq prime = {UINT64_C(0xb9feffffffffaaab), UINT64_C(0x1eabfffeb153ffff),
                         UINT64_C(0x6730d2a0f6b0f624), UINT64_C(0x64774b84f38512bf),
                         UINT64_C(0x4b1ba7b6434bacd7), UINT64_C(0x1a0111ea397fe69a)};
static const fq r_squared = {UINT64_C(0xf4df1f341c341746), UINT64_C(0x0a76e6a609d104f1),
                             UINT64_C(0x8de5476c4c95b6d5), UINT64_C(0x67eb88a9939d83c0),
                             UINT64_C(0x9a793e85b519952d), UINT64_C(0x11988fe592cae3aa)};
static const fq mont_one = {UINT64_C(0x760900000002fffd), UINT64_C(0xebf4000bc40c0002),
                            UINT64_C(0x5f48985753c758ba), UINT64_C(0x77ce585370525745),
                            UINT64_C(0x5c071a97a256ec6d), UINT64_C(0x15f65ec3fa80e493)};
static const fq half_prime = {UINT64_C(0xdcff7fffffffd555), UINT64_C(0x0f55ffff58a9ffff),
                              UINT64_C(0xb39869507b587b12), UINT64_C(0xb23ba5c279c2895f),
                              UINT64_C(0x258dd3db21a5d66b), UINT64_C(0x0d0088f51cbff34d)};
static const uint64_t neg_inverse = UINT64_C(0x89f3fffcfffcfffd);

static int zero(const fq a) { return !(a[0] | a[1] | a[2] | a[3] | a[4] | a[5]); }
static void add(fq out, const fq a, const fq b) {
  mpn_add_n(out, a, b, 6);
  if (mpn_cmp(out, prime, 6) >= 0)
    mpn_sub_n(out, out, prime, 6);
}
static void sub(fq out, const fq a, const fq b) {
  if (mpn_sub_n(out, a, b, 6))
    mpn_add_n(out, out, prime, 6);
}

static void reduce(fq out, mp_limb_t product[13]) {
  for (unsigned i = 0; i < 6; ++i) {
    mp_limb_t factor = product[i] * neg_inverse;
    mp_limb_t carry = mpn_addmul_1(product + i, prime, 6, factor);
    mpn_add_1(product + i + 6, product + i + 6, 7 - i, carry);
  }
  memcpy(out, product + 6, sizeof(fq));
  if (mpn_cmp(out, prime, 6) >= 0)
    mpn_sub_n(out, out, prime, 6);
}
static void mul(fq out, const fq a, const fq b) {
  mp_limb_t t[13];
  t[12] = 0;
  mpn_mul_n(t, a, b, 6);
  reduce(out, t);
}
static void square(fq out, const fq a) {
  mp_limb_t t[13];
  t[12] = 0;
  mpn_sqr(t, a, 6);
  reduce(out, t);
}
static void canonical(fq out, const fq a) {
  mp_limb_t t[13] = {0};
  memcpy(t, a, sizeof(fq));
  reduce(out, t);
}

static void twice(point *p) {
  if (zero(p->z) || zero(p->y)) {
    memset(p, 0, sizeof *p);
    return;
  }
  fq yy, s, m, tmp;
  point out;
  square(yy, p->y);
  mul(s, p->x, yy);
  add(s, s, s);
  add(s, s, s);
  square(tmp, p->x);
  add(m, tmp, tmp);
  add(m, m, tmp);
  square(out.x, m);
  sub(out.x, out.x, s);
  sub(out.x, out.x, s);
  sub(tmp, s, out.x);
  mul(out.y, m, tmp);
  square(tmp, yy);
  add(tmp, tmp, tmp);
  add(tmp, tmp, tmp);
  add(tmp, tmp, tmp);
  sub(out.y, out.y, tmp);
  mul(tmp, p->y, p->z);
  add(out.z, tmp, tmp);
  *p = out;
}

/* Both points now have a common affine denominator z. */
static void combine(point *p, const fq u1, const fq s1, const fq u2, const fq s2, const fq z) {
  fq h, r, hh, hhh, v, t;
  point out;
  sub(h, u2, u1);
  sub(r, s2, s1);
  if (zero(h)) {
    if (zero(r))
      twice(p);
    else
      memset(p, 0, sizeof *p);
    return;
  }
  square(hh, h);
  mul(hhh, h, hh);
  mul(v, u1, hh);
  square(out.x, r);
  sub(out.x, out.x, hhh);
  sub(out.x, out.x, v);
  sub(out.x, out.x, v);
  sub(t, v, out.x);
  mul(out.y, r, t);
  mul(t, s1, hhh);
  sub(out.y, out.y, t);
  mul(out.z, h, z);
  *p = out;
}
static void add_mixed(point *p, const affine *q) {
  if (zero(p->z)) {
    memcpy(p->x, q->x, sizeof(fq));
    memcpy(p->y, q->y, sizeof(fq));
    memcpy(p->z, mont_one, sizeof(fq));
    return;
  }
  fq zz, x, y;
  square(zz, p->z);
  mul(x, q->x, zz);
  mul(y, zz, p->z);
  mul(y, y, q->y);
  combine(p, p->x, p->y, x, y, p->z);
}
static void add_point(point *p, const point *q) {
  if (zero(q->z))
    return;
  if (zero(p->z)) {
    *p = *q;
    return;
  }
  fq z1, z2, u1, s1, u2, s2, z;
  square(z1, p->z);
  square(z2, q->z);
  mul(u1, p->x, z2);
  mul(u2, q->x, z1);
  mul(s1, q->z, z2);
  mul(s1, s1, p->y);
  mul(s2, p->z, z1);
  mul(s2, s2, q->y);
  mul(z, p->z, q->z);
  combine(p, u1, s1, u2, s2, z);
}

static void write_coordinate(unsigned char *dst, const fq a) {
  for (unsigned i = 0; i < 6; ++i)
    for (unsigned j = 0; j < 8; ++j)
      *dst++ = (unsigned char)(a[i] >> (8 * j));
}
static void read_coordinate(fq out, const unsigned char *src) {
  fq n;
  for (unsigned i = 0; i < 6; ++i) {
    uint64_t word = 0;
    for (unsigned j = 0; j < 8; ++j)
      word |= (uint64_t)*src++ << (8 * j);
    n[i] = word;
  }
  mul(out, n, r_squared);
}
static void encode(unsigned char dst[48], const point *p) {
  if (zero(p->z)) {
    memset(dst, 0, 48);
    dst[47] = 0xc0;
    return;
  }
  fq zi, zz, x, y;
  canonical(zi, p->z);
  mpz_t n, m;
  mpz_inits(n, m, NULL);
  mpz_import(n, 6, -1, sizeof(mp_limb_t), 0, 0, zi);
  mpz_import(m, 6, -1, sizeof(mp_limb_t), 0, 0, prime);
  mpz_invert(n, n, m);
  memset(zi, 0, sizeof zi);
  mpz_export(zi, NULL, -1, sizeof(mp_limb_t), 0, 0, n);
  mpz_clears(n, m, NULL);
  mul(zi, zi, r_squared);
  square(zz, zi);
  mul(x, p->x, zz);
  mul(y, zi, zz);
  mul(y, p->y, y);
  canonical(x, x);
  canonical(y, y);
  write_coordinate(dst, x);
  dst[47] |= mpn_cmp(y, half_prime, 6) > 0 ? 0xa0 : 0x80;
}

struct window_task {
  const unsigned char *scalars;
  const affine *bases;
  size_t n;
  unsigned width, first, last;
  point *buckets, *windows;
};

static void *sum_windows(void *argument) {
  struct window_task *task = argument;
  const unsigned char *scalars = task->scalars;
  const affine *bases = task->bases;
  const size_t n = task->n;
  unsigned width = task->width, count = 1u << width;
  point *buckets = task->buckets;
  for (unsigned window = task->first; window < task->last; ++window) {
    memset(buckets, 0, count * sizeof *buckets);
    unsigned bit = window * width, byte = bit / 8, shift = bit % 8;
    for (size_t i = 0; i < n; ++i) {
      const unsigned char *v = scalars + 32 * i;
      unsigned digit = ((v[byte] | ((byte < 31 ? v[byte + 1] : 0) << 8)) >> shift) & (count - 1);
      if (digit)
        add_mixed(&buckets[digit], &bases[i]);
    }
    point sum = {0};
    for (unsigned j = count - 1; j > 0; --j) {
      add_point(&sum, &buckets[j]);
      add_point(&task->windows[window], &sum);
    }
  }
  return NULL;
}

CAMLprim value cvm_bls_msm(value table, value coefficients, value output) {
  size_t bytes = caml_string_length(coefficients), n = bytes / 32;
  if (bytes % 32 || n > 4096 || caml_string_length(table) < n * 96 || caml_string_length(output) != 48)
    caml_invalid_argument("BLS12-381 MSM dimensions");
  const unsigned char *scalars = (const unsigned char *)String_val(coefficients);
  unsigned width = n < 32 ? 3 : n < 192 ? 5 : n < 640 ? 7 : 9, count = 1u << width;
  affine *bases = malloc((n ? n : 1) * sizeof *bases);
  /* Each window has independent affine buckets. Use at most three helper
     threads and keep small commitments on the caller. */
  unsigned workers = n >= 512 ? 4 : n >= 128 ? 2 : 1;
  point *buckets = calloc(count * workers, sizeof *buckets);
  if (!bases || !buckets) {
    free(bases);
    free(buckets);
    caml_raise_out_of_memory();
  }
  unsigned bits = 0;
  for (size_t i = 0; i < n; ++i) {
    const unsigned char *v = scalars + 32 * i;
    unsigned j = 32;
    while (j && !v[j - 1])
      --j;
    if (!j)
      continue;
    unsigned used = 8 * (j - 1) + (32 - __builtin_clz((unsigned)v[j - 1]));
    if (used > bits)
      bits = used;
    const unsigned char *coords = (const unsigned char *)String_val(table) + 96 * i;
    read_coordinate(bases[i].x, coords);
    read_coordinate(bases[i].y, coords + 48);
  }
  unsigned windows = (bits + width - 1) / width;
  /* A 256-bit integer needs at most 86 three-bit windows. */
  point totals[86] = {0};
  struct window_task tasks[4];
  pthread_t threads[3];
  int launched[3] = {0};
  for (unsigned i = 0; i < workers; ++i) {
    tasks[i] = (struct window_task){scalars,
                                    bases,
                                    n,
                                    width,
                                    windows * i / workers,
                                    windows * (i + 1) / workers,
                                    buckets + count * i,
                                    totals};
    if (i + 1 < workers)
      launched[i] = pthread_create(&threads[i], NULL, sum_windows, &tasks[i]) == 0;
  }
  sum_windows(&tasks[workers - 1]);
  for (unsigned i = 0; i + 1 < workers; ++i) {
    if (launched[i])
      pthread_join(threads[i], NULL);
    else
      sum_windows(&tasks[i]);
  }
  point acc = {0};
  for (unsigned window = windows; window-- > 0;) {
    for (unsigned j = 0; j < width; ++j)
      twice(&acc);
    add_point(&acc, &totals[window]);
  }
  encode((unsigned char *)Bytes_val(output), &acc);
  free(bases);
  free(buckets);
  return Val_unit;
}
