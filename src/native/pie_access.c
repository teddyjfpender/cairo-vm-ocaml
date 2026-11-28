/* Count unique addresses of a completed, single-word-per-step trace. Each
   range has private bits. Only the caller touches the OCaml result array. */
#include "trace_encoding.h"
#include <caml/bigarray.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

struct segment_range {
  size_t first, words;
};
struct access_job {
  value icache, pages;
  const uint64_t *trace;
  const intnat *stack;
  size_t stack_size, nseg, begin, end, program_size;
  const struct segment_range *range;
  uint64_t *bits;
  int ok;
};

static inline int record(struct access_job *j, intnat seg, intnat off) {
  if (off < 0)
    return 1;
  if ((uintnat)seg >= j->nseg)
    return 0;
  if (seg == 0 && (uintnat)off < j->program_size)
    return 1;
  struct segment_range r = j->range[seg];
  if (!r.words)
    return 1; /* Excluded builtin or finalized zero segment. */
  size_t word = (size_t)off >> 6;
  if (word >= r.words)
    return 0;
  j->bits[r.first + word] |= UINT64_C(1) << (off & 63);
  return 1;
}

/* The array is sorted by segment and by 1024-cell code page. */
static value page_for(value pages, intnat seg, intnat base) {
  size_t lo = 0, hi = Wosize_val(pages);
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    value entry = Field(pages, mid);
    intnat s = Long_val(Field(entry, 0)), b = Long_val(Field(entry, 1));
    if (s == seg && b == base)
      return Field(entry, 2);
    if (s < seg || (s == seg && b < base))
      lo = mid + 1;
    else
      hi = mid;
  }
  return Val_unit;
}

static void *scan(void *arg) {
  struct access_job *j = arg;
  intnat last_seg = -1, last_base = -1;
  value last_page = Val_unit;
  for (size_t i = j->begin; i < j->end; ++i) {
    uint64_t w = j->trace[i];
    intnat pc, ap, fp, seg = 0, index;
    value words;
    int blake = 0;
    if (w & 1) {
      pc = (w >> 47) & 65535;
      ap = (w >> 24) & 0x7fffff;
      fp = (w >> 1) & 0x7fffff;
      words = Field(j->icache, 0);
      index = pc;
    } else {
      if (w & 2)
        return NULL;
      trace_unpack_dynamic(w, &seg, &pc, &ap, &fp);
      intnat base = pc & ~(intnat)1023;
      if (seg != last_seg || base != last_base) {
        last_page = page_for(j->pages, seg, base);
        last_seg = seg;
        last_base = base;
      }
      if (last_page == Val_unit)
        return NULL;
      words = last_page;
      index = pc - base;
    }
    if ((uintnat)index >= Wosize_val(words))
      return NULL;
    uint64_t d = Long_val(Field(words, index));
    if (!d && seg == 0 && (uintnat)pc < Wosize_val(Field(j->icache, 1))) {
      d = Long_val(Field(Field(j->icache, 1), pc));
      int ext = (d >> 61) & 3;
      blake = ext == 1 || ext == 2;
    }
    if (!d)
      return NULL;
    if (blake && (uintnat)ap < j->stack_size) {
      intnat out = j->stack[ap];
      if ((out & 3) == 2) {
        intnat off = (out >> 2) & ((INT64_C(1) << 40) - 1);
        for (int k = 0; k < 8; ++k)
          if (!record(j, out >> 42, off + k))
            return NULL;
      }
    }
    intnat dst = ((d >> 48) & 1 ? fp : ap) + (int)(d & 65535) - 32768;
    intnat op0 = ((d >> 49) & 1 ? fp : ap) + (int)((d >> 16) & 65535) - 32768;
    intnat delta = (int)((d >> 32) & 65535) - 32768;
    if (!record(j, 1, dst) || !record(j, 1, op0) || !record(j, seg, pc))
      return NULL;
    switch ((d >> 50) & 3) {
    case 0: {
      intnat a = (uintnat)op0 < j->stack_size ? j->stack[op0] : 0;
      if ((a & 3) == 2 && !record(j, a >> 42, ((a >> 2) & ((INT64_C(1) << 40) - 1)) + delta))
        return NULL;
      break;
    }
    case 1:
      if (!record(j, seg, pc + 1))
        return NULL;
      break;
    case 2:
      if (!record(j, 1, fp + delta))
        return NULL;
      break;
    case 3:
      if (!record(j, 1, ap + delta))
        return NULL;
      break;
    }
  }
  j->ok = 1;
  return NULL;
}

value cvm_pie_access(value trace, value length, value icache, value pages, value stack, value sizes,
                     value counts, value program) {
  enum { MAX_LANES = 4, MAX_BYTES = 32 << 20 };
  size_t nseg = Wosize_val(sizes), n = Long_val(length), total = 0;
  long cpus = sysconf(_SC_NPROCESSORS_ONLN);
  size_t lanes = cpus > MAX_LANES ? MAX_LANES : cpus > 0 ? (size_t)cpus : 1;
  if (lanes < 2 || nseg < 2 || n > (size_t)Caml_ba_array_val(trace)->dim[0])
    return Val_false;
  struct segment_range *ranges = calloc(nseg, sizeof(*ranges));
  if (!ranges)
    return Val_false;
  for (size_t s = 0; s < nseg; ++s) {
    intnat size = Long_val(Field(sizes, s));
    /* Allow a final instruction to address just beyond the used memory. */
    size_t words = size < 0 ? 0 : (size_t)size / 64 + 2;
    if (words > MAX_BYTES / (lanes * 8) - total) {
      free(ranges);
      return Val_false;
    }
    ranges[s] = (struct segment_range){total, words};
    total += words;
  }
  uint64_t *maps = calloc(total * lanes, sizeof(*maps));
  if (!maps) {
    free(ranges);
    return Val_false;
  }
  struct access_job jobs[MAX_LANES];
  pthread_t threads[MAX_LANES];
  size_t spawned = 0;
  for (size_t k = 0; k < lanes; ++k) {
    jobs[k] = (struct access_job){.icache = icache,
                                  .pages = pages,
                                  .trace = Caml_ba_data_val(trace),
                                  .stack = Caml_ba_data_val(stack),
                                  .stack_size = (size_t)Caml_ba_array_val(stack)->dim[0],
                                  .nseg = nseg,
                                  .begin = n * k / lanes,
                                  .end = n * (k + 1) / lanes,
                                  .program_size = (size_t)Long_val(program),
                                  .range = ranges,
                                  .bits = maps + total * k};
  }
  for (; spawned + 1 < lanes; ++spawned)
    if (pthread_create(&threads[spawned], NULL, scan, &jobs[spawned]) != 0)
      break;
  if (spawned + 1 == lanes)
    scan(&jobs[spawned]);
  for (size_t k = 0; k < spawned; ++k)
    pthread_join(threads[k], NULL);
  int ok = 1;
  for (size_t k = 0; k < lanes; ++k)
    if (!jobs[k].ok)
      ok = 0;
  if (ok) {
    for (size_t s = 0; s < nseg; ++s) {
      size_t cnt = s == 0 ? (size_t)Long_val(program) : 0;
      for (size_t i = ranges[s].first; i < ranges[s].first + ranges[s].words; ++i) {
        uint64_t bits = maps[i];
        for (size_t k = 1; k < lanes; ++k)
          bits |= maps[k * total + i];
        cnt += __builtin_popcountll(bits);
      }
      Field(counts, s) = Val_long(cnt);
    }
  }
  free(maps);
  free(ranges);
  return Val_bool(ok);
}

value cvm_pie_access_byte(value *v, int argc) {
  (void)argc;
  return cvm_pie_access(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
}
