#include "field.h"

/* Parse a canonical hex field element from the sequencer JSON. Zero is
   the empty-cell sentinel, distinct from the field element 0. */
static intnat parse_hex(value pool, const unsigned char *s, size_t n, intnat slot) {
  if (n <= 2 || n > 66 || s[0] != '0' || (s[1] != 'x' && s[1] != 'X')) return 0;
  u64 limbs[4] = {0};
  /* Values are offset by one so every unlisted byte is invalid. Parse
     one 64-bit word at a time, starting with the least significant. */
  static const uint8_t hex[256] = {
    ['0']=1, ['1']=2, ['2']=3, ['3']=4, ['4']=5, ['5']=6, ['6']=7, ['7']=8, ['8']=9, ['9']=10,
    ['a']=11, ['b']=12, ['c']=13, ['d']=14, ['e']=15, ['f']=16,
    ['A']=11, ['B']=12, ['C']=13, ['D']=14, ['E']=15, ['F']=16
  };
  size_t remaining = n - 2;
  for (unsigned limb = 0; remaining; ++limb) {
    size_t count = remaining > 16 ? 16 : remaining;
    const unsigned char *start = s + 2 + remaining - count;
    u64 word = 0;
    for (size_t i = 0; i < count; ++i) {
      unsigned digit = hex[start[i]];
      if (!digit) return 0;
      word = (word << 4) | (digit - 1);
    }
    limbs[limb] = word;
    remaining -= count;
  }
  if (geq_p(limbs)) return 0;
  return store(pool, limbs, slot);
}

intnat cvm_parse_hex(value pool, value text, intnat slot) {
  return parse_hex(pool, (const unsigned char *)String_val(text), caml_string_length(text), slot);
}

/* The fallback reader accepts escaped strings, integers, and other field
   spellings. This fast path handles arrays of quoted canonical hex words. */
value cvm_hex_array_count(value text, value bounds) {
  size_t first = Long_val(Field(bounds, 0)), last = Long_val(Field(bounds, 1));
  if (first > last || last > caml_string_length(text)) return Val_long(0);
  const unsigned char *p = (const unsigned char *)String_val(text) + first;
  size_t size = last - first, count = 1;
  if (size == 0 || p[0] != '[') return Val_long(0);
  for (size_t i = 0; i < size; ++i) count += p[i] == ',';
  return Val_long(count);
}

static inline int json_space(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

value cvm_hex_array_parse(value pool, value text, value out, value start, value bounds) {
  size_t first = Long_val(Field(bounds, 0)), last = Long_val(Field(bounds, 1));
  if (first > last || last > caml_string_length(text)) return Val_long(-1);
  const unsigned char *base = (const unsigned char *)String_val(text);
  const unsigned char *p = base + first, *end = base + last;
  size_t n = Wosize_val(out), capacity = Caml_ba_array_val(pool)->dim[0] / 32;
  intnat slot = Long_val(start);
  if (slot < 0 || (uintnat)slot > capacity || p == end || *p++ != '[') return Val_long(-1);
  for (size_t i = 0; i < n; ++i) {
    while (p < end && json_space(*p)) ++p;
    if (p == end || *p++ != '"' || (uintnat)slot >= capacity) return Val_long(-1);
    const unsigned char *close = memchr(p, '"', (size_t)(end-p));
    if (!close) return Val_long(-1);
    intnat code = parse_hex(pool, p, (size_t)(close-p), slot);
    if (!code) return Val_long(-1);
    if ((code & 3) == 3 && (code >> 2) == slot) ++slot;
    Field(out, i) = Val_long(code);
    p = close + 1;
    while (p < end && json_space(*p)) ++p;
    if (p == end || *p++ != (i+1 < n ? ',' : ']')) return Val_long(-1);
  }
  return p == end ? Val_long(slot) : Val_long(-1);
}

value cvm_parse_hex_byte(value pool, value text, value slot) {
  return Val_long(cvm_parse_hex(pool, text, Long_val(slot)));
}
