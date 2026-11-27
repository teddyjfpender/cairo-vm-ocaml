#ifndef CVM_TRACE_ENCODING_H
#define CVM_TRACE_ENCODING_H
#include <stdint.h>
#include <caml/mlvalues.h>

/* The generic OCaml writer in Cpu.record_trace uses the same tags. A compact
   dynamic entry uses 10:18:24:9 bits for segment, PC, AP, and AP minus FP.
   The suffix 00 distinguishes it from a full relocatable PC (suffix 10). */
static inline int trace_pack_dynamic(intnat seg, intnat pc, intnat ap, intnat fp,
                                     uint64_t *word) {
  uintnat depth = (uintnat)ap - (uintnat)fp;
  if ((uintnat)seg >= 1024 || (uintnat)pc >= (1 << 18) ||
      (uintnat)ap >= (1 << 24) || depth >= 512) return 0;
  *word = ((uint64_t)seg << 53) | ((uint64_t)pc << 35) |
          ((uint64_t)ap << 11) | (depth << 2);
  return 1;
}

static inline void trace_unpack_dynamic(uint64_t word, intnat *seg, intnat *pc,
                                        intnat *ap, intnat *fp) {
  *seg = (word >> 53) & 1023;
  *pc = (word >> 35) & 0x3ffff;
  *ap = (word >> 11) & 0xffffff;
  *fp = *ap - ((word >> 2) & 511);
}
#endif
