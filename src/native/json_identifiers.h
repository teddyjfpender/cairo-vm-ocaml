/* Emit common identifier records into a reusable OCaml scratch array. All
   unrecognized structures remain with the existing projection reader. */
static const unsigned char *id_string(const unsigned char **cursor,
                                      const unsigned char *end,
                                      size_t *length) {
  const unsigned char *p = whitespace(*cursor, end);
  if (p == end || *p++ != '"')
    return NULL;
  const unsigned char *start = p;
  int escaped = 0;
  p = string_end(p, end, &escaped);
  if (!p || escaped)
    return NULL;
  *length = (size_t)(p - start - 1);
  *cursor = p;
  return start;
}

#define ID_IS(key)                                                             \
  (length == (sizeof(key) - 1) && !memcmp(name, key, sizeof(key) - 1))
static const unsigned char *
read_identifier(value input, const unsigned char *base, const unsigned char *p,
                const unsigned char *end, value rows, intnat row) {
  size_t length;
  const unsigned char *id = id_string(&p, end, &length);
  if (!id)
    return NULL;
  size_t id_len = length;
  if (!json_take_token(&p, end, ":", 1) || !json_take_token(&p, end, "{", 1))
    return NULL;
  int kind = 0;
  intnat pc = -1, destination = -1, destination_length = 0, number = -1,
         number_length = 0;
  for (;;) {
    const unsigned char *name = id_string(&p, end, &length);
    if (!name || !json_take_token(&p, end, ":", 1))
      return NULL;
    if (ID_IS("members"))
      return NULL;
    if (ID_IS("type")) {
      if (kind)
        return NULL;
      name = id_string(&p, end, &length);
      if (!name)
        return NULL;
      if (ID_IS("reference"))
        kind = 1;
      else if (ID_IS("type_definition"))
        kind = 2;
      else if (ID_IS("namespace"))
        kind = 3;
      else if (ID_IS("function"))
        kind = 4;
      else if (ID_IS("alias"))
        kind = 5;
      else if (ID_IS("const"))
        kind = 6;
      else if (ID_IS("label"))
        kind = 7;
      else
        return NULL;
    } else if (ID_IS("pc")) {
      uintnat n;
      if (pc != -1 || !json_take_unsigned(&p, end, &n))
        return NULL;
      pc = (intnat)n;
    } else if (ID_IS("destination")) {
      if (destination != -1)
        return NULL;
      const unsigned char *text = id_string(&p, end, &length);
      if (!text)
        return NULL;
      destination = text - base;
      destination_length = (intnat)length;
    } else if (ID_IS("value")) {
      if (number != -1)
        return NULL;
      p = whitespace(p, end);
      const unsigned char *start = p;
      if (p < end && *p == '-')
        ++p;
      if (p == end || !digit(*p))
        return NULL;
      if (*p++ != '0')
        while (p < end && digit(*p))
          ++p;
      number = start - base;
      number_length = p - start;
    } else {
      intnat after = Long_val(cvm_json_skip(input, Val_long(p - base)));
      if (after < 0)
        return NULL;
      p = base + after;
    }
    if (json_take_token(&p, end, "}", 1))
      break;
    if (!json_take_token(&p, end, ",", 1))
      return NULL;
  }
  if (!kind)
    return NULL;
  Field(rows, row) = Val_long(id - base);
  Field(rows, row + 1) = Val_long(id_len);
  Field(rows, row + 2) = Val_long(kind);
  Field(rows, row + 3) = Val_long(pc);
  Field(rows, row + 4) = Val_long(destination);
  Field(rows, row + 5) = Val_long(destination_length);
  Field(rows, row + 6) = Val_long(number);
  Field(rows, row + 7) = Val_long(number_length);
  return p;
}
#undef ID_IS

/* A row contains identifier name start/length, kind, PC, destination
   start/length and integer literal start/length. Only publish rows through a
   complete record boundary. Leave its comma for the surrounding JSON reader. */
CAMLprim value cvm_json_identifier_block(value input, value position,
                                         value rows) {
  size_t start = Long_val(Field(position, 0)),
         length = caml_string_length(input);
  if (start >= length)
    return Val_int(0);
  const unsigned char *base = (const unsigned char *)String_val(input),
                      *end = base + length;
  const unsigned char *p = base + start;
  intnat count = 0, capacity = Wosize_val(rows);
  while (count + 8 <= capacity) {
    const unsigned char *after =
        read_identifier(input, base, p, end, rows, count);
    if (!after)
      break;
    count += 8;
    Field(position, 0) = Val_long(after - base);
    p = after;
    if (!json_take_token(&p, end, ",", 1))
      break;
  }
  return Val_long(count);
}
