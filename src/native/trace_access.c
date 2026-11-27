/* Process cached Stone instructions in the finalized trace. Leave an
   uncached instruction or bitmap growth to Resources.update_accessed.
   Marking is idempotent, so the fallback can repeat a partial entry. */
#include <stdint.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

static inline int mark(value maps, value counts, intnat seg, intnat off) {
  if (seg < 0 || off < 0) return 1;
  if ((uintnat)seg >= Wosize_val(maps)) return 0;
  value map = Field(maps, seg);
  if ((uintnat)off >= caml_string_length(map)) return 0;
  unsigned char *cell = (unsigned char *)Bytes_val(map) + off;
  if (!*cell) {
    *cell = 1;
    Field(counts, seg) += 2;
  }
  return 1;
}

value cvm_trace_access(value trace, value end, value cache, value stack,
                       value maps, value counts, value state, value page) {
  const uint64_t *entries = Caml_ba_data_val(trace);
  const intnat *cells = Caml_ba_data_val(stack);
  const size_t stack_len = Caml_ba_array_val(stack)->dim[0];
  intnat cursor = Long_val(Field(state, 0)), stop = Long_val(end);
  intnat lo = Long_val(Field(state, 1)), hi = Long_val(Field(state, 2));
  while (cursor < stop) {
    uint64_t w = entries[cursor];
    intnat pc, ap, fp, code_seg = 0, width;
    value words = cache;
    intnat base_pc = 0;
    if (w & 1) {
      pc = (w >> 47) & 0xffff;
      ap = (w >> 24) & 0x7fffff;
      fp = (w >> 1) & 0x7fffff;
      width = 1;
    } else {
      if (stop-cursor < 3) break;
      code_seg = (intnat)w >> 42;
      pc = (w >> 2) & ((UINT64_C(1) << 40) - 1);
      ap = entries[cursor+1];
      fp = entries[cursor+2];
      width = 3;
      if (code_seg != 0) {
        if (code_seg != Long_val(Field(state, 3))) break;
        words = page;
        base_pc = Long_val(Field(state, 4));
      }
    }
    if ((uintnat)(pc-base_pc) >= Wosize_val(words)) break;
    uint64_t d = Long_val(Field(words, pc-base_pc));
    if (!d) break;
    int f0 = d & 65535, f1 = (d >> 16) & 65535, f2 = (d >> 32) & 65535;
    intnat dst = ((d >> 48) & 1 ? fp : ap) + f0 - 32768;
    intnat op0 = ((d >> 49) & 1 ? fp : ap) + f1 - 32768;
    if (!mark(maps, counts, 1, dst) || !mark(maps, counts, 1, op0)) break;
    intnat seg = 1, base = 0, delta = f2 - 32768;
    switch ((d >> 50) & 3) {
      case 0: {
        intnat a = (uintnat)op0 < stack_len ? cells[op0] : 0;
        if ((a & 3) != 2) { seg = -1; break; }
        seg = a >> 42;
        base = (a >> 2) & ((UINT64_C(1) << 40) - 1);
        break;
      }
      case 1: seg = code_seg; base = pc; delta = 1; break;
      case 2: base = fp; break;
      case 3: base = ap; break;
    }
    if (!mark(maps, counts, seg, base + delta) || !mark(maps, counts, code_seg, pc)) break;
    if (f0 < lo) lo = f0;
    if (f1 < lo) lo = f1;
    if (f2 < lo) lo = f2;
    if (f0 > hi) hi = f0;
    if (f1 > hi) hi = f1;
    if (f2 > hi) hi = f2;
    cursor += width;
  }
  Field(state, 0) = Val_long(cursor);
  Field(state, 1) = Val_long(lo);
  Field(state, 2) = Val_long(hi);
  return Val_unit;
}

value cvm_trace_access_byte(value *argv, int argc) {
  (void)argc;
  return cvm_trace_access(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7]);
}
