#include "field.h"

/* The header is big endian. Word magnitudes are little endian, without
   redundant high zero bytes. An empty magnitude denotes zero. */
static intnat scan(value raw, value output, value pool, intnat cursor) {
  const unsigned char *p = (const unsigned char *)String_val(raw);
  size_t size = caml_string_length(raw);
  if (size < 4) return -1;
  const unsigned char *end = p + size;
  uint32_t count = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                   ((uint32_t)p[2] << 8) | p[3];
  p += 4;
  if (count > (uint32_t)(4u << 20) || count > size - 4) return -1;
  int write = output != Val_unit;
  size_t capacity = write ? Caml_ba_array_val(pool)->dim[0] / 32 : 0;
  if (write && (Wosize_val(output) != count || cursor < 0)) return -1;
  for (uint32_t i = 0; i < count; ++i) {
    if (p == end) return -1;
    unsigned width = *p++;
    if (width > 32 || (size_t)(end - p) < width || (width && !p[width-1])) return -1;
    u64 limbs[4] = {0};
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    memcpy(limbs, p, width);
#else
    for (unsigned j = 0; j < width; ++j)

      limbs[j / 8] |= (u64)p[j] << ((j % 8) * 8);
#endif
    p += width;
    if (geq_p(limbs)) return -1;
    if (write) {
      if ((uintnat)cursor >= capacity) return -2;
      intnat code = store(pool, limbs, cursor);
      if ((code & 3) == 3 && (code >> 2) == cursor) ++cursor;
      Field(output, i) = Val_long(code);
    }
  }
  return p == end ? (write ? cursor : (intnat)count) : -1;
}

value cvm_witness_words_count(value raw) {
  return Val_long(scan(raw, Val_unit, Val_unit, 0));
}

value cvm_witness_words_load(value raw, value output, value pool, value cursor) {
  return Val_long(scan(raw, output, pool, Long_val(cursor)));
}

/* Schema keys and hexadecimal state values are usually ASCII. A machine-word
   check lets the decoder use the standard UTF-8 validator for the remainder. */
value cvm_witness_ascii(value text) {
  const unsigned char *p = (const unsigned char *)String_val(text);
  size_t n = caml_string_length(text);
  u64 high = 0;
  while (n >= 8) {
    u64 word;
    memcpy(&word, p, sizeof word);
    high |= word;
    p += 8;
    n -= 8;
  }
  if (high & UINT64_C(0x8080808080808080)) return Val_false;
  while (n--) if (*p++ >= 128) return Val_false;
  return Val_true;
}
