/* Validate a JSON value without allocating OCaml nodes for unused program
   metadata. Track nested containers explicitly so deep input cannot exhaust
   the native call stack. */
#include <caml/mlvalues.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static inline int digit(unsigned char c) { return c >= '0' && c <= '9'; }
static inline int hex(unsigned char c) {
  return digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static const unsigned char *whitespace(const unsigned char *p, const unsigned char *end) {
  while (p < end) {
    unsigned char c = *p;
    if (c != ' ' && c != '\n' && c != '\r' && c != '\t') break;
    ++p;
    /* Compiler debug locations are heavily indented. Skip whole groups of
       spaces without accepting other control characters as whitespace. */
    while (end - p >= 8) {
      uint64_t word;
      memcpy(&word, p, sizeof word);
      if (word != UINT64_C(0x2020202020202020)) break;
      p += sizeof word;
    }
  }
  return p;
}

static inline uint64_t zero_bytes(uint64_t w) {
  return (w - UINT64_C(0x0101010101010101)) & ~w & UINT64_C(0x8080808080808080);
}

static const unsigned char *string_end(const unsigned char *p, const unsigned char *end,
                                       int *escaped) {
  while (p < end) {
    while (end-p >= 8) {
      uint64_t w;
      memcpy(&w, p, sizeof(w));
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
      w = __builtin_bswap64(w);
#endif
      uint64_t special = zero_bytes(w ^ UINT64_C(0x2222222222222222)) |
                         zero_bytes(w ^ UINT64_C(0x5c5c5c5c5c5c5c5c)) |
                         zero_bytes(w & UINT64_C(0xe0e0e0e0e0e0e0e0));
      if (special) {
        p += __builtin_ctzll(special) / 8;
        break;
      }
      p += 8;
    }
    if (p == end) break;
    unsigned char c = *p++;
    if (c == '"') return p;
    if (c < 0x20) return NULL;
    if (c != '\\') continue;
    if (p == end) return NULL;
    if (escaped) *escaped = 1;
    switch (*p++) {
    case '"': case '\\': case '/': case 'b': case 'f': case 'n': case 'r': case 't':
      break;
    case 'u':
      if (end-p < 4 || !hex(p[0]) || !hex(p[1]) || !hex(p[2]) || !hex(p[3])) return NULL;
      p += 4;
      break;
    default: return NULL;
    }
  }
  return NULL;
}

/* Sign indicates that the string needs unescaping. Zero denotes invalid input. */
CAMLprim value cvm_json_string_end(value input, value index) {
  const unsigned char *base = (const unsigned char *)String_val(input);
  const unsigned char *end = base + caml_string_length(input);
  intnat i = Long_val(index);
  int escaped = 0;
  if (i < 0 || (uintnat)i >= (uintnat)(end-base)) return Val_long(0);
  const unsigned char *next = string_end(base+i, end, &escaped);
  if (!next) return Val_long(0);
  intnat offset = next-base;
  return Val_long(escaped ? -offset : offset);
}

static const unsigned char *number_end(const unsigned char *p, const unsigned char *end) {
  if (*p == '-') ++p;
  if (p == end || !digit(*p)) return NULL;
  if (*p++ != '0') while (p < end && digit(*p)) ++p;
  if (p < end && *p == '.') {
    if (++p == end || !digit(*p)) return NULL;
    do { ++p; } while (p < end && digit(*p));
  }
  if (p < end && (*p == 'e' || *p == 'E')) {
    ++p;
    if (p < end && (*p == '-' || *p == '+')) ++p;
    if (p == end || !digit(*p)) return NULL;
    do { ++p; } while (p < end && digit(*p));
  }
  return p;
}

/* Return the first byte after the value, or a negative error offset. */
CAMLprim value cvm_json_skip(value input, value index) {
  const unsigned char *base = (const unsigned char *)String_val(input);
  const unsigned char *end = base + caml_string_length(input);
  intnat start = Long_val(index);
  if (start < 0 || (uintnat)start >= (uintnat)(end-base)) return Val_long(-1);
  const unsigned char *p = base + start, *next;
  unsigned char local[64], *stack = local;
  size_t depth = 0, capacity = sizeof(local);
  intnat result;
read_value:
  p = whitespace(p, end);
  if (p == end) goto invalid;
  if (*p == '[' || *p == '{') {
    unsigned char close = *p++ == '[' ? ']' : '}';
    p = whitespace(p, end);
    if (p < end && *p == close) { ++p; goto completed; }
    if (depth == capacity) {
      unsigned char *larger = malloc(capacity * 2);
      if (!larger) goto invalid;
      memcpy(larger, stack, depth);
      if (stack != local) free(stack);
      stack = larger;
      capacity *= 2;
    }
    stack[depth++] = close;
    if (close == '}') goto read_key;
    goto read_value;
  }
  if (*p == '"') next = string_end(p+1, end, NULL);
  else if (digit(*p) || *p == '-') next = number_end(p, end);
  else {
    const char *literal = *p == 't' ? "true" : *p == 'f' ? "false" : "null";
    size_t length = strlen(literal);
    if ((size_t)(end-p) < length || memcmp(p, literal, length)) goto invalid;
    next = p + length;
  }
  if (!next) goto invalid;
  p = next;
completed:
  if (!depth) { result = p-base; goto done; }
  p = whitespace(p, end);
  if (p == end) goto invalid;
  if (*p == stack[depth-1]) { ++p; --depth; goto completed; }
  if (*p++ != ',') goto invalid;
  if (stack[depth-1] == ']') goto read_value;
  p = whitespace(p, end);
read_key:
  if (p == end || *p != '"') goto invalid;
  next = string_end(p+1, end, NULL);
  if (!next) goto invalid;
  p = whitespace(next, end);
  if (p == end || *p++ != ':') goto invalid;
  goto read_value;
invalid:
  result = -1 - (p-base);
done:
  if (stack != local) free(stack);
  return Val_long(result);
}

/* Resolve an object key against the canonical names in an Only projection.
   Returning the matching list tail avoids allocating either a key or an
   option. Escaped names use the full JSON decoder in the caller. */
CAMLprim value cvm_json_project_key(value input, value position, value fields) {
  const unsigned char *base = (const unsigned char *)String_val(input);
  size_t length = caml_string_length(input);
  intnat start = Long_val(Field(position, 0));
  if ((uintnat)start >= length || base[start] != '"') return Val_emptylist;
  const unsigned char *key = base + start + 1;
  int escaped = 0;
  const unsigned char *after = string_end(key, base + length, &escaped);
  if (!after || escaped) return Val_emptylist;
  Field(position, 0) = Val_long(after - base);
  size_t bytes = (size_t)(after - key - 1);
  for (; fields != Val_emptylist; fields = Field(fields, 1)) {
    value name = Field(Field(fields, 0), 0);
    if (bytes == caml_string_length(name) && !memcmp(key, String_val(name), bytes)) break;
  }
  return fields;
}

#include "json_schema.h"

/* Find a candidate debug object in indented compiler JSON. Its actual key,
   start and end are checked independently by the parser and schema validator.
   A compact or differently formatted file uses the ordinary parser. */
CAMLprim value cvm_json_debug_span(value input, value bounds) {
  static const char key[] = "\"debug_info\"";
  const unsigned char *base = (const unsigned char *)String_val(input);
  const unsigned char *end = base + caml_string_length(input);
  const unsigned char *p = base;
  while ((p = memchr(p, 'd', (size_t)(end - p))) != NULL) {
    const unsigned char *name = p++;
    if (name == base || (size_t)(end - name) < sizeof key - 2 ||
        memcmp(name - 1, key, sizeof key - 1) != 0) continue;
    --name;
    const unsigned char *indent = name;
    while (indent > base && indent[-1] == ' ') --indent;
    if (indent == base || indent[-1] != '\n') continue;
    size_t spaces = (size_t)(name - indent);
    if (spaces > 64) continue;
    const unsigned char *colon = whitespace(name + sizeof key - 1, end);
    if (colon == end || *colon != ':') continue;
    const unsigned char *first = whitespace(colon + 1, end);
    if (first == end || *first != '{') continue;
    /* In sorted compiler output hints follows debug_info. Search from the
       smaller metadata tail before walking through megabytes of locations.
       The caller verifies both ends against the complete root and schema. */
    const unsigned char *block_end = end;
    while (block_end > first + 1) {
      size_t left = (size_t)(block_end - first - 1);
      const unsigned char *block = block_end - (left > 65536 ? 65536 : left);
      const unsigned char *q = block;
      while ((q = memchr(q, 'h', (size_t)(block_end - q))) != NULL) {
        const unsigned char *h = q++;
        if ((size_t)(end-h) < 6 || (size_t)(h - first) <= spaces + 2 || h[-1] != '"' ||
            memcmp(h,"hints\"",6) || h[-(ptrdiff_t)spaces-2] != '\n' ||
            memcmp(h-spaces-1, indent, spaces)) continue;
        const unsigned char *comma = h-spaces-2;
        while (comma > first+1 && (comma[-1] == ' ' || comma[-1] == '\r' ||
                                    comma[-1] == '\t' || comma[-1] == '\n')) --comma;
        if (comma - first <= 2 || comma[-1] != ',' || comma[-2] != '}') continue;
        if (comma-1-first < 2000000) continue;
        Field(bounds, 0) = Val_long((intnat)(first-base));
        Field(bounds, 1) = Val_long((intnat)(comma-1-base));
        return Val_true;
      }
      block_end = block;
      /* Unsorted and differently indented inputs have the ordinary path. */
      if (end-block > (end-first)/3) break;
    }
    const unsigned char *close = first + 1;
    while ((close = memchr(close, '}', (size_t)(end-close))) != NULL) {
      if ((size_t)(close-first) > spaces && close[-(ptrdiff_t)spaces-1] == '\n' &&
          memcmp(close-spaces, indent, spaces) == 0) {
        if (close-first < 2000000) return Val_false;
        Field(bounds, 0) = Val_long((intnat)(first-base));
        Field(bounds, 1) = Val_long((intnat)(close+1-base));
        return Val_true;
      }
      ++close;
    }
    return Val_false;
  }
  return Val_false;
}

/* Match exactly the bytes of a previously parsed complete JSON value. */
CAMLprim value cvm_json_matches_at(value source, value offset, value key) {
  size_t at = Long_val(offset), length = caml_string_length(source);
  size_t size = caml_string_length(key);
  return Val_bool(at <= length && size <= length - at &&
                  !memcmp(String_val(source) + at, String_val(key), size));
}
