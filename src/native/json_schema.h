/* Fast validation for the data constructors in Program_metadata.schema.
   Unusual spellings and deep inputs return to the original OCaml validator. */
struct json_span { const unsigned char *start; size_t length; };
struct schema_reader {
  value source;
  value projected_instruction;
  int debug_root;
  const unsigned char *base, *end, *p;
  struct json_span previous[32];
  int allow_partition;
};
/* Text is immediate. Block tags follow the declaration order of the other
   constructors in src/program/program_metadata.ml. */
enum schema_tag { S_UNSIGNED, S_OPTIONAL, S_ARRAY, S_PAIR, S_MAP, S_RECORD };

static int schema_uint(const unsigned char *p, size_t n, uint64_t limit) {
  if (!n || (n > 1 && *p == '0'))
    return 0;
  uint64_t v = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned d = (unsigned)p[i] - '0';
    if (d > 9 || v > (limit - d) / 10)
      return 0;
    v = v * 10 + d;
  }
  return 1;
}
/* Compiler records frequently repeat the same arrays or maps at adjacent
   locations. A span validated in this source can be reused only on an exact
   byte match. Object and array closing delimiters make each span unambiguous. */
static int schema_skip_cached(struct schema_reader *s, const unsigned char *key,
                              size_t key_length, int split_object) {
  const unsigned char *first = whitespace(s->p, s->end);
  if (first == s->end) return 0;
  unsigned slot = (unsigned)(key_length * 11 + (key_length ? key[0] : 0));
  struct json_span *span = &s->previous[slot % 32];
  int container = *first == '{' || *first == '[';
  if (container && span->length && (size_t)(s->end-first) >= span->length &&
      !memcmp(first, span->start, span->length)) {
    s->p = first + span->length;
    return 1;
  }
  if (split_object && *first == '{') {
    const unsigned char *p = whitespace(first+1, s->end);
    if (p == s->end) return 0;
    if (*p != '}') for (;;) {
      if (*p != '"') return 0;
      const unsigned char *name = p+1, *after = string_end(name, s->end, NULL);
      if (!after) return 0;
      p = whitespace(after, s->end);
      if (p == s->end || *p != ':') return 0;
      s->p = p+1;
      if (!schema_skip_cached(s, name, (size_t)(after-name-1), 0)) return 0;
      p = whitespace(s->p, s->end);
      if (p == s->end) return 0;
      if (*p == '}') break;
      if (*p != ',') return 0;
      p = whitespace(p+1, s->end);
      if (p == s->end) return 0;
    }
    s->p = p + 1;
  } else {
    intnat pos = Long_val(skip_bytes(s->base, s->end, Val_long(first - s->base)));
    if (pos < 0 || (uintnat)pos > (size_t)(s->end-s->base)) return 0;
    s->p = s->base + pos;
  }
  if (container && s->p-first >= 32) {
    span->start = first;
    span->length = (size_t)(s->p-first);
  }
  return 1;
}
static int schema_take(struct schema_reader *s, unsigned char c) {
  const unsigned char *p = whitespace(s->p, s->end);
  s->p = p;
  if (p == s->end || *p != c)
    return 0;
  s->p = p + 1;
  return 1;
}
#include <pthread.h>

static int schema_value(struct schema_reader *s, value spec, unsigned depth);

struct map_partition {
  struct schema_reader reader;
  value element;
  unsigned depth;
  const unsigned char *boundary;
  int valid;
};

/* Validate consecutive integer-keyed map members. A left partition must
   reach its exact separating comma; a right partition ends at the map close. */
static void *validate_partition(void *arg) {
  struct map_partition *part = arg;
  struct schema_reader *s = &part->reader;
  for (;;) {
    if (!schema_take(s, '"'))
      return NULL;
    const unsigned char *key = s->p;
    while (s->p < s->end && digit(*s->p))
      ++s->p;
    if (!schema_uint(key, (size_t)(s->p - key), UINT64_MAX) || s->p == s->end ||
        *s->p++ != '"' || !schema_take(s, ':') ||
        !schema_value(s, part->element, part->depth + 1))
      return NULL;
    const unsigned char *after = whitespace(s->p, s->end);
    if (after == s->end)
      return NULL;
    if (part->boundary && after >= part->boundary) {
      part->valid = after == part->boundary && *after == ',';
      return NULL;
    }
    if (*after == '}') {
      s->p = after + 1;
      part->valid = part->boundary == NULL;
      return NULL;
    }
    if (*after != ',')
      return NULL;
    s->p = after + 1;
  }
}

static int split_instruction_map(struct schema_reader *s, value element,
                                 unsigned depth) {
  const unsigned char *first = whitespace(s->p, s->end);
  if (s->end - first < 16000000 || *first != '"')
    return 0;
  const unsigned char *line = first;
  while (line > s->p && line[-1] == ' ')
    --line;
  size_t indent = (size_t)(first - line);
  if (line == s->p || line[-1] != '\n' || indent > 64)
    return 0;
  const unsigned char *scan = first + (s->end - first) / 2;
  const unsigned char *limit = scan + 131072;
  while ((scan = memchr(scan, '\n', (size_t)(limit - scan))) != NULL) {
    const unsigned char *nl = scan++;
    if ((size_t)(s->end - scan) < indent + 2 || memcmp(scan, line, indent) ||
        scan[indent] != '"' || !digit(scan[indent + 1]))
      continue;
    const unsigned char *comma = nl;
    while (comma > first &&
           (comma[-1] == ' ' || comma[-1] == '\r' || comma[-1] == '\t'))
      --comma;
    if (comma == first || comma[-1] != ',')
      continue;
    --comma;
    struct map_partition left = {*s, element, depth, comma, 0};
    struct map_partition right = {*s, element, depth, NULL, 0};
    right.reader.p = comma + 1;
    pthread_t worker;
    if (pthread_create(&worker, NULL, validate_partition, &right))
      return 0;
    validate_partition(&left);
    pthread_join(worker, NULL);
    if (!left.valid || !right.valid)
      return 0;
    s->p = right.reader.p;
    return 1;
  }
  return 0;
}

static int schema_value(struct schema_reader *s, value spec, unsigned depth) {
  s->p = whitespace(s->p, s->end);
  if (s->p == s->end || depth > 100)
    return 0;
  if (Is_long(spec)) {
    if (*s->p != '"')
      return 0;
    const unsigned char *start = ++s->p;
    int escaped = 0;
    const unsigned char *end = string_end(start, s->end, &escaped);
    if (!end)
      return 0;
    if (escaped) {
      for (const unsigned char *q = start; q + 1 < end; ++q)
        if (*q == '\\' && *++q == 'u')
          return 0;
    }
    s->p = end;
    return 1;
  }
  tag_t tag = Tag_val(spec);
  value child = Field(spec, 0);
  if (tag == S_UNSIGNED) {
    const unsigned char *start = s->p;
    while (s->p < s->end && digit(*s->p))
      ++s->p;
    return schema_uint(start, s->p - start,
                       Long_val(child) == 32 ? UINT32_MAX : UINT64_MAX);
  }
  if (tag == S_OPTIONAL) {
    if (s->end - s->p >= 4 && !memcmp(s->p, "null", 4)) {
      s->p += 4;
      return 1;
    }
    return schema_value(s, child, depth + 1);
  }
  if (tag == S_PAIR)
    return schema_take(s, '[') && schema_value(s, child, depth + 1) &&
           schema_take(s, ',') && schema_value(s, Field(spec, 1), depth + 1) &&
           schema_take(s, ']');
  if (tag == S_ARRAY) {
    if (!schema_take(s, '['))
      return 0;
    if (schema_take(s, ']'))
      return 1;
    do {
      if (!schema_value(s, child, depth + 1))
        return 0;
    } while (schema_take(s, ','));
    return schema_take(s, ']');
  }
  if ((tag != S_MAP && tag != S_RECORD) || !schema_take(s, '{'))
    return 0;
  if (tag == S_MAP && s->allow_partition && s->debug_root && Bool_val(child) &&
      Field(spec, 1) == s->projected_instruction &&
      split_instruction_map(s, Field(spec, 1), depth)) return 1;
  uint64_t seen = 0;
  if (!schema_take(s, '}')) {
    do {
      if (!schema_take(s, '"'))
        return 0;
      const unsigned char *key = s->p;
      int escaped = 0;
      s->p = string_end(key, s->end, &escaped);
      if (!s->p || escaped)
        return 0;
      size_t n = (size_t)(s->p - key - 1);
      if (!schema_take(s, ':'))
        return 0;
      if (tag == S_MAP) {
        if (Bool_val(child) && !schema_uint(key, n, UINT64_MAX))
          return 0;
        if (!schema_value(s, Field(spec, 1), depth + 1))
          return 0;
      } else {
        value list = child;
        unsigned i = 0;
        while (list != Val_emptylist) {
          value pair = Field(list, 0), name = Field(pair, 0);
          if (i >= 63)
            return 0;
          if (n == caml_string_length(name) &&
              !memcmp(key, String_val(name), n)) {
            uint64_t bit = UINT64_C(1) << i;
            if ((seen & bit) || !schema_value(s, Field(pair, 1), depth + 1))
              return 0;
            seen |= bit;
            break;
          }
          list = Field(list, 1);
          ++i;
        }
        /* The original Debug_info projection skips unknown top-level members.
             For other unknown fields, defer to its original JSON projection. */
        if (list == Val_emptylist &&
            (!(s->debug_root &&
               (depth == 1 || spec == s->projected_instruction)) ||
             !schema_skip_cached(s, key, n, 1)))
          return 0;
      }
    } while (schema_take(s, ','));
    if (!schema_take(s, '}'))
      return 0;
  }
  if (tag == S_RECORD) {
    unsigned i = 0;
    for (value list = child; list != Val_emptylist;
         list = Field(list, 1), ++i) {
      value v = Field(Field(list, 0), 1);
      if (i >= 63 || (!(seen & (UINT64_C(1) << i)) &&
                      (Is_long(v) || Tag_val(v) != S_OPTIONAL)))
        return 0;
    }
  }
  return 1;
}
CAMLprim value cvm_json_validate_schema(value source, value position,
                                        value spec,
                                        value projected_instruction) {
  const unsigned char *base = (const unsigned char *)String_val(source);
  size_t n = caml_string_length(source);
  intnat i = Long_val(Field(position, 0));
  if ((uintnat)i >= n)
    return Val_false;
  struct schema_reader s = {source,
                            projected_instruction,
                            Is_block(spec) && Tag_val(spec) == S_OPTIONAL,
                            base,
                            base + n,
                            base + i};
  if (!schema_value(&s, spec, 0))
    return Val_false;
  Field(position, 0) = Val_long(s.p - s.base);
  return Val_true;
}


/* The calling OCaml domain retains its runtime lock throughout this noalloc
   primitive. Any native worker only borrows immutable source/schema blocks,
   performs no OCaml allocation or callback, and is joined before we return.
   A candidate end offset can precede the actual value on unusual input. */
CAMLprim value cvm_json_validate_debug_range(value source, value bounds,
                                             value spec,
                                             value projected_instruction) {
  const unsigned char *base = (const unsigned char *)String_val(source);
  size_t size = caml_string_length(source);
  uintnat first = Long_val(Field(bounds, 0)), last = Long_val(Field(bounds, 1));
  if (first >= last || last > size)
    return Val_false;
  struct schema_reader reader = {.source = source,
                                 .projected_instruction = projected_instruction,
                                 .debug_root = 1,
                                 .base = base,
                                 .end = base + last,
                                 .p = base + first,
                                 .allow_partition = 1};
  return Val_bool(schema_value(&reader, spec, 0) && reader.p == reader.end);
}
