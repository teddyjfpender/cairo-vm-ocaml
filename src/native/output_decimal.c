/* Write complete, signed Cairo words into a bounded output buffer. Fields are
   already canonical limbs. Every signed 252-bit decimal value and its newline
   fit within 80 bytes. */
#include "field.h"
#include <gmp.h>

_Static_assert(GMP_NUMB_BITS == 64, "Cairo output requires 64-bit GMP limbs");

static char *unsigned_decimal(char *dst, uint64_t n) {
  char digits[20], *end = digits + sizeof digits, *p = end;
  do {
    *--p = (char)('0' + n % 10);
    n /= 10;
  } while (n);
  size_t size = (size_t)(end - p);
  memcpy(dst, p, size);
  return dst + size;
}

static char *signed_decimal(char *dst, int64_t n) {
  if (n >= 0)
    return unsigned_decimal(dst, (uint64_t)n);
  *dst++ = '-';
  return unsigned_decimal(dst, -(uint64_t)n);
}

static char *field_decimal(char *dst, const u64 *input) {
  static const u64 half[4] = {0, 0, UINT64_C(0x8000000000000000),
                              UINT64_C(0x0400000000000008)};
  u64 magnitude[4];
  int index = 3;
  while (index && input[index] == half[index])
    --index;
  if (input[index] > half[index]) {
    *dst++ = '-';
    sub4(magnitude, P, input);
  } else
    memcpy(magnitude, input, sizeof magnitude);
  int size = 4;
  while (size > 1 && !magnitude[size - 1])
    --size;
  if (size == 1)
    return unsigned_decimal(dst, magnitude[0]);
  mp_limb_t limbs[4];
  memcpy(limbs, magnitude, sizeof limbs);
  unsigned char digits[80];
  size_t count = mpn_get_str(digits, 10, limbs, size), i = 0;
  while (i + 1 < count && !digits[i])
    ++i;
  for (; i < count; ++i)
    *dst++ = (char)('0' + digits[i]);
  return dst;
}

CAMLprim value cvm_output_chunk(value pool, value segment, value used,
                                value cursor, value buffer) {
  const intnat *cells = Caml_ba_data_val(segment);
  intnat index = Long_val(Field(cursor, 0)), stop = Long_val(used);
  size_t length = caml_string_length(buffer);
  if (index < 0 || stop < index || length < 80)
    return Val_long(-1);
  char *start = (char *)Bytes_val(buffer), *p = start;
  size_t capacity = Caml_ba_array_val(segment)->dim[0];
  while (index < stop && (size_t)(p - start) <= length - 80) {
    intnat code = (uintnat)index < capacity ? cells[index] : 0;
    if (!code) {
      memcpy(p, "<missing>", 9);
      p += 9;
    } else if ((code & 3) == 1)
      p = signed_decimal(p, code >> 2);
    else if ((code & 3) == 2) {
      p = signed_decimal(p, code >> 42);
      *p++ = ':';
      p = unsigned_decimal(p, (code >> 2) & UINT64_C(0xffffffffff));
    } else
      p = field_decimal(p, SLOT(pool, code >> 2));
    *p++ = '\n';
    ++index;
  }
  Field(cursor, 0) = Val_long(index);
  return Val_long(p - start);
}
