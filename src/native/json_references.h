/* Recognize the compiler's ordinary reference encoding. The reader falls back
   to its general projection on a different key order, spelling, or value. */
static int json_take_token(const unsigned char **p, const unsigned char *end,
                           const char *token, size_t size) {
  const unsigned char *at = whitespace(*p, end);
  if ((size_t)(end - at) < size || memcmp(at, token, size))
    return 0;
  *p = at + size;
  return 1;
}
#define REF_TOKEN(s) json_take_token(&p, end, (s), sizeof(s) - 1)

static int json_take_unsigned(const unsigned char **cursor,
                              const unsigned char *end, uintnat *result) {
  const unsigned char *p = whitespace(*cursor, end);
  if (p == end || !digit(*p))
    return 0;
  uintnat value = *p++ - '0';
  if (value && p < end && digit(*p))
    do {
      unsigned d = *p++ - '0';
      if (value > ((uintnat)Max_long - d) / 10)
        return 0;
      value = value * 10 + d;
    } while (p < end && digit(*p));
  *cursor = p;
  *result = value;
  return 1;
}

/* Rows hold group, offset, string start and string length. A negative length
   denotes a lexically valid escape to decode from the original quoted bytes.
   A full block returns zero after consuming its comma. A positive count marks
   the end of the entire manager. A mismatch leaves the caller's cursor alone.
 */
CAMLprim value cvm_json_reference_block(value input, value position,
                                        value initial, value output) {
  size_t start = Long_val(Field(position, 0));
  size_t words = Wosize_val(output);
  if (start >= caml_string_length(input) || words < 4 || words % 4)
    return Val_int(-1);
  const unsigned char *base = (const unsigned char *)String_val(input);
  const unsigned char *end = base + caml_string_length(input);
  const unsigned char *p = base + start;
  if (Bool_val(initial) && (!REF_TOKEN("{") || !REF_TOKEN("\"references\"") ||
                            !REF_TOKEN(":") || !REF_TOKEN("[")))
    return Val_int(-1);
  intnat count = 0;
  do {
    uintnat group, offset, pc;
    if (!REF_TOKEN("{") || !REF_TOKEN("\"ap_tracking_data\"") ||
        !REF_TOKEN(":") || !REF_TOKEN("{") || !REF_TOKEN("\"group\"") ||
        !REF_TOKEN(":") || !json_take_unsigned(&p, end, &group) ||
        !REF_TOKEN(",") || !REF_TOKEN("\"offset\"") || !REF_TOKEN(":") ||
        !json_take_unsigned(&p, end, &offset) || !REF_TOKEN("}") ||
        !REF_TOKEN(",") || !REF_TOKEN("\"pc\"") || !REF_TOKEN(":") ||
        !json_take_unsigned(&p, end, &pc) || !REF_TOKEN(",") ||
        !REF_TOKEN("\"value\"") || !REF_TOKEN(":") || !REF_TOKEN("\""))
      return Val_int(-1);
    const unsigned char *text = p;
    int escaped = 0;
    p = string_end(p, end, &escaped);
    if (!p)
      return Val_int(-1);
    if (escaped) {
      for (const unsigned char *q = text; q + 1 < p; ++q)
        if (*q == '\\' && *++q == 'u')
          return Val_int(-1);
    }
    Field(output, count) = Val_long(group);
    Field(output, count + 1) = Val_long(offset);
    Field(output, count + 2) = Val_long(text - base);
    Field(output, count + 3) =
        Val_long(escaped ? -(p - text - 1) : p - text - 1);
    count += 4;
    if (!REF_TOKEN("}"))
      return Val_int(-1);
    if (!REF_TOKEN(","))
      break;
    if ((size_t)count == words) {
      Field(position, 0) = Val_long(p - base);
      return Val_int(0);
    }
  } while (1);
  if (!REF_TOKEN("]") || !REF_TOKEN("}"))
    return Val_int(-1);
  Field(position, 0) = Val_long(p - base);
  return Val_long(count);
}
#undef REF_TOKEN
