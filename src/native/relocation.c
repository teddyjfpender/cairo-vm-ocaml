/* Rewrite pointers in assigned memory after all temporary segment destinations
   have been resolved. The runner moves the segments using checked writes. */
#include <stdint.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

CAMLprim value cvm_relocate_segments(value segments, value highs, value count, value rules) {
  const intnat n = Long_val(count);
  const intnat mask = (INT64_C(1) << 40) - 1;
  if ((uintnat)n > Wosize_val(segments) || (uintnat)n > Wosize_val(highs)) return Val_false;
  for (intnat s = 0; s < n; ++s) {
    value segment = Field(segments, s);
    intnat *cells = Caml_ba_data_val(segment);
    const intnat length = Long_val(Field(highs, s));
    if ((uintnat)length > (uintnat)Caml_ba_array_val(segment)->dim[0]) return Val_false;
    for (intnat i = 0; i < length; ++i) {
      const intnat v = cells[i];
      if (v < 0 && (v & 3) == 2) {
        const intnat index = -1 - (v >> 42);
        if ((uintnat)index >= Wosize_val(rules)) continue;
        const intnat base = Long_val(Field(rules, index));
        if (base == 0) continue;
        const intnat delta = (v >> 2) & mask;
        if (delta > mask - ((base >> 2) & mask)) return Val_false;
        cells[i] = base + (delta << 2);
      }
    }
  }
  return Val_true;
}
