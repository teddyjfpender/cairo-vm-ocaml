/* Validate and discard large compiler debug maps while the OCaml parser
   reads the rest of the document. No native worker receives an OCaml pointer.
   The fast grammar is deliberately narrower than Program_metadata: any
   unfamiliar layout is retried with the complete general reader. */
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

#define TILE (2u * 1024 * 1024)
#define OVERLAP (128u * 1024)
struct tile_limits {
  size_t start, finish;
};
struct stream_job {
  int fd, lane, lanes, valid;
  size_t first, size;
  struct tile_limits *limits;
};

/* The scanner proposes a separator near each tile boundary. Parsing to the
   exact comma rejects guesses inside nested values. */
static const unsigned char *tile_boundary(const unsigned char *p,
                                          const unsigned char *end) {
  while ((p = memchr(p, ',', (size_t)(end - p)))) {
    const unsigned char *at = p++;
    if (p == end || *p != '\n')
      continue;
    const unsigned char *q = p + 1;
    size_t spaces = 0;
    while (q < end && *q == ' ' && spaces < 64) {
      ++spaces;
      ++q;
    }
    if (!spaces || end - q < 2 || *q != '"' || !digit(q[1]))
      continue;
    return at;
  }
  return NULL;
}

#define EXPECT(s, literal)                                                     \
  json_take_token(&(s)->p, (s)->end, literal, sizeof(literal) - 1)

static int tile_uint(struct schema_reader *s) {
  const unsigned char *p = whitespace(s->p, s->end), *start = p;
  while (p < s->end && digit(*p))
    ++p;
  s->p = p;
  return schema_uint(start, p - start, UINT32_MAX);
}
static int tile_text(struct schema_reader *s) {
  return schema_value(s, Val_int(0), 0);
}

static int tile_location(struct schema_reader *s, unsigned depth) {
  if (depth > 50 || !EXPECT(s, "{") || !EXPECT(s, "\"end_col\"") ||
      !EXPECT(s, ":") || !tile_uint(s) || !EXPECT(s, ",") ||
      !EXPECT(s, "\"end_line\"") || !EXPECT(s, ":") || !tile_uint(s) ||
      !EXPECT(s, ",") || !EXPECT(s, "\"input_file\"") || !EXPECT(s, ":") ||
      !EXPECT(s, "{") || !EXPECT(s, "\"filename\"") || !EXPECT(s, ":") ||
      !tile_text(s) || !EXPECT(s, "}") || !EXPECT(s, ","))
    return 0;
  if (EXPECT(s, "\"parent_location\"")) {
    if (!EXPECT(s, ":"))
      return 0;
    if (!EXPECT(s, "null") &&
        (!EXPECT(s, "[") || !tile_location(s, depth + 1) || !EXPECT(s, ",") ||
         !tile_text(s) || !EXPECT(s, "]")))
      return 0;
    if (!EXPECT(s, ","))
      return 0;
  }
  return EXPECT(s, "\"start_col\"") && EXPECT(s, ":") && tile_uint(s) &&
         EXPECT(s, ",") && EXPECT(s, "\"start_line\"") && EXPECT(s, ":") &&
         tile_uint(s) && EXPECT(s, "}");
}

static int tile_instruction(struct schema_reader *s) {
  if (!EXPECT(s, "{") || !EXPECT(s, "\"accessible_scopes\"") ||
      !EXPECT(s, ":") ||
      !schema_skip_cached(s, (const unsigned char *)"accessible_scopes", 17,
                          1) ||
      !EXPECT(s, ",") || !EXPECT(s, "\"flow_tracking_data\"") ||
      !EXPECT(s, ":") ||
      !schema_skip_cached(s, (const unsigned char *)"flow_tracking_data", 18,
                          1) ||
      !EXPECT(s, ",") || !EXPECT(s, "\"hints\"") || !EXPECT(s, ":") ||
      !EXPECT(s, "["))
    return 0;
  if (!EXPECT(s, "]")) {
    do {
      if (!EXPECT(s, "{") || !EXPECT(s, "\"location\"") || !EXPECT(s, ":") ||
          !tile_location(s, 0) || !EXPECT(s, ",") ||
          !EXPECT(s, "\"n_prefix_newlines\"") || !EXPECT(s, ":") ||
          !tile_uint(s) || !EXPECT(s, "}"))
        return 0;
    } while (EXPECT(s, ","));
    if (!EXPECT(s, "]"))
      return 0;
  }
  return EXPECT(s, ",") && EXPECT(s, "\"inst\"") && EXPECT(s, ":") &&
         tile_location(s, 0) && EXPECT(s, "}");
}

static int tile_map(struct schema_reader *s, const unsigned char *boundary) {
  do {
    if (!EXPECT(s, "\""))
      return 0;
    const unsigned char *k = s->p;
    while (s->p < s->end && digit(*s->p))
      ++s->p;
    if (!schema_uint(k, s->p - k, UINT64_MAX) || s->p == s->end ||
        *s->p++ != '"' || !EXPECT(s, ":") || !tile_instruction(s))
      return 0;
    s->p = whitespace(s->p, s->end);
    if (boundary && s->p >= boundary)
      return s->p == boundary && *s->p == ',';
    if (EXPECT(s, "}"))
      return !boundary;
  } while (EXPECT(s, ","));
  return 0;
}
static int exact_pread(int fd, unsigned char *buf, size_t len, size_t at);
static void *stream_lane(void *arg) {
  struct stream_job *job = arg;
  unsigned char *bytes = malloc(TILE + OVERLAP);
  if (!bytes)
    return NULL;
  for (size_t off = (size_t)job->lane * TILE; off < job->size;
       off += (size_t)job->lanes * TILE) {
    size_t remaining = job->size - off;
    size_t n = remaining > TILE + OVERLAP ? TILE + OVERLAP : remaining;
    if (!exact_pread(job->fd, bytes, n, job->first + off))
      goto done;
    struct schema_reader reader = {
        .base = bytes, .end = bytes + n, .p = bytes, .debug_root = 1};
    const unsigned char *boundary = NULL;
    struct tile_limits *limits = &job->limits[off / TILE];
    if (off) {
      const unsigned char *end = bytes + (n < OVERLAP ? n : OVERLAP);
      const unsigned char *at = tile_boundary(bytes, end);
      if (!at)
        goto done;
      reader.p = at + 1;
      limits->start = off + (size_t)(at - bytes);
    } else {
      const unsigned char *p = bytes, *end = bytes + n;
#define TK(s) json_take_token(&p, end, s, sizeof(s) - 1)
      if (!TK("{") || !TK("\"file_contents\"") || !TK(":"))
        goto done;
      intnat next = Long_val(skip_bytes(bytes, end, Val_long(p - bytes)));
      if (next < 0)
        goto done;
      p = bytes + next;
      if (!TK(",") || !TK("\"instruction_locations\"") || !TK(":") || !TK("{"))
        goto done;
      reader.p = p;
#undef TK
    }
    if (remaining > TILE) {
      boundary = tile_boundary(bytes + TILE, bytes + n);
      if (!boundary)
        goto done;
      limits->finish = off + (size_t)(boundary - bytes);
    }
    if (!tile_map(&reader, boundary))
      goto done;
    if (!boundary && (!schema_take(&reader, '}') || reader.p != reader.end))
      goto done;
  }
  job->valid = 1;
done:
  free(bytes);
  return NULL;
}

static void *stream_supervisor(void *arg) {
  struct stream_job *a = arg, b = *a;
  b.lane = 1;
  pthread_t worker;
  int launched = pthread_create(&worker, NULL, stream_lane, &b) == 0;
  stream_lane(a);
  if (launched)
    pthread_join(worker, NULL);
  else
    stream_lane(&b);
  a->valid = a->valid && b.valid;
  return NULL;
}
/* Compare precise descriptor timestamps and length around all independent
   reads. Both neighboring tiles must independently report the same offset.
   A filesystem mutation or short read retries the ordinary descriptor path. */
static int file_stamp(int fd, intnat stamp[5]) {
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode))
    return 0;
#ifdef __APPLE__
  struct timespec m = st.st_mtimespec, c = st.st_ctimespec;
#else
  struct timespec m = st.st_mtim, c = st.st_ctim;
#endif
  stamp[0] = st.st_size;
  stamp[1] = m.tv_sec;
  stamp[2] = m.tv_nsec;
  stamp[3] = c.tv_sec;
  stamp[4] = c.tv_nsec;
  return 1;
}

CAMLprim value cvm_stream_debug(value descriptor, value bounds,
                                value callback) {
  CAMLparam1(callback);
  CAMLlocal1(result);
  if (Wosize_val(bounds) != 7)
    CAMLreturn(Val_false);
  size_t first = Long_val(Field(bounds, 0)), last = Long_val(Field(bounds, 1));
  intnat stamp[5], after[5];
  for (int i = 0; i < 5; ++i)
    stamp[i] = Long_val(Field(bounds, i + 2));
  if (first >= last || last > (size_t)stamp[0])
    CAMLreturn(Val_false);
  size_t n = (last - first - 1) / TILE + 1;
  if (n > 4096)
    CAMLreturn(Val_false);
  struct tile_limits *limits = calloc(n, sizeof(*limits));
  if (!limits)
    CAMLreturn(Val_false);
  struct stream_job job = {Int_val(descriptor), 0,     2, 0, first,
                           last - first,        limits};
  pthread_t worker;
  if (pthread_create(&worker, NULL, stream_supervisor, &job)) {
    free(limits);
    CAMLreturn(Val_false);
  }
  result = caml_callback_exn(callback, Val_unit);
  int raised = Is_exception_result(result);
  if (raised)
    result = Extract_exception(result);
  /* Pending OCaml handlers may raise. Always join before delivering them. */
  caml_enter_blocking_section_no_pending();
  pthread_join(worker, NULL);
  int valid = job.valid && file_stamp(job.fd, after) &&
              !memcmp(stamp, after, sizeof(stamp));
  for (size_t i = 1; valid && i < n; ++i)
    valid = limits[i].start == limits[i - 1].finish;
  free(limits);
  caml_leave_blocking_section();
  if (raised)
    caml_raise(result);
  CAMLreturn(Val_bool(valid));
}

static int exact_pread(int fd, unsigned char *buf, size_t len, size_t at) {
  while (len) {
    ssize_t n = pread(fd, buf, len, (off_t)at);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return 0;
    at += (size_t)n;
    buf += n;
    len -= (size_t)n;
  }
  return 1;
}

/* Propose debug endpoints from bounded probes in pretty-printed compiler
   output. The complete root and debug schema independently verify them. */
CAMLprim value cvm_file_span(value descriptor, value length, value bounds) {
  int fd = Int_val(descriptor);
  size_t size = Long_val(length), found = 0;
  const size_t head = 1u << 20, chunk = 256u << 10, overlap = 256;
  intnat stamp[5];
  if (size < head * 4 || Wosize_val(bounds) != 7 || !file_stamp(fd, stamp) ||
      (size_t)stamp[0] != size)
    return Val_false;
  unsigned char *buf = malloc(head);
  if (!buf)
    return Val_false;
  size_t start = 0, indent = 0, finish = 0;
  if (!exact_pread(fd, buf, head, 0))
    goto done;
  const unsigned char *p = buf, *end = buf + head;
  while ((p = memchr(p, 'd', (size_t)(end - p))) != NULL) {
    const unsigned char *d = p++;
    if (d <= buf || end - d < 11 || memcmp(d - 1, "\"debug_info\"", 12) ||
        d[-1] != '"')
      continue;
    const unsigned char *line = d - 1;
    while (line > buf && line[-1] == ' ')
      --line;
    if (line == buf || line[-1] != '\n')
      continue;
    const unsigned char *q = d + 11;
    if (!json_take_token(&q, end, ":", 1))
      continue;
    q = whitespace(q, end);
    if (q == end || *q != '{')
      continue;
    start = q - buf;
    indent = d - 1 - line;
    break;
  }
  if (!start || indent > 64)
    goto done;
  for (size_t hi = size; hi > size / 2;) {
    size_t lo = hi > chunk ? hi - chunk : 0;
    size_t at = lo > overlap ? lo - overlap : 0;
    size_t n = hi - at;
    if (!exact_pread(fd, buf, n, at))
      goto done;
    end = buf + n;
    p = buf;
    while ((p = memchr(p, 'h', (size_t)(end - p))) != NULL) {
      const unsigned char *h = p++;
      if ((size_t)(h - buf) < indent + 4 || end - h < 6 || h[-1] != '"' ||
          memcmp(h, "hints\"", 6))
        continue;
      const unsigned char *q = h - 1;
      size_t spaces = 0;
      while (q > buf && q[-1] == ' ') {
        --q;
        ++spaces;
      }
      if (spaces != indent || q == buf || q[-1] != '\n')
        continue;
      --q;
      while (q > buf &&
             (q[-1] == ' ' || q[-1] == '\r' || q[-1] == '\n' || q[-1] == '\t'))
        --q;
      if (q - buf < 2 || q[-1] != ',' || q[-2] != '}')
        continue;
      finish = at + (size_t)(q - 1 - buf);
      if (finish > start + 16000000) {
        found = 1;
        goto done;
      }
    }
    hi = lo + overlap;
  }
done:
  free(buf);
  if (found) {
    Field(bounds, 0) = Val_long(start);
    Field(bounds, 1) = Val_long(finish);
    for (int i = 0; i < 5; ++i)
      Field(bounds, i + 2) = Val_long(stamp[i]);
  }
  return Val_bool(found);
}
