/* Independent raw DEFLATE blocks, joined on byte-aligned Z_SYNC_FLUSH
   boundaries. A final empty stored block terminates the member in OCaml. */
#include <caml/mlvalues.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <zlib.h>

enum { MAX_BLOCKS = 4 };

struct block {
  const Bytef *src;
  Bytef *dst;
  unsigned size, capacity, written;
  int level;
  bool production, last;
  uLong crc;
};

#include "pie_deflate_fast.h"

static void *compress_block(void *arg) {
  struct block *b = arg;
  if (b->production) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
    extern ptrdiff_t ox_pie_deflate_range(const unsigned char *, size_t, bool, unsigned char *, size_t);
    ptrdiff_t count = ox_pie_deflate_range(b->src, b->size, b->last, b->dst, b->capacity);
    if (count > 0) {
      b->written = (unsigned)count;
      b->crc = crc32(0, b->src, b->size);
    }
#endif
    return NULL;
  }
#ifdef OXC_HAVE_LIBDEFLATE
  if (compress_fast(b)) return NULL;
#endif
  z_stream stream = {0};
  if (deflateInit2(&stream, b->level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    return NULL;
  stream.next_in = (Bytef *)b->src;
  stream.avail_in = b->size;
  stream.next_out = b->dst;
  stream.avail_out = b->capacity;
  if (deflate(&stream, Z_SYNC_FLUSH) == Z_OK && !stream.avail_in && stream.avail_out) {
    b->written = (unsigned)stream.total_out;
    b->crc = crc32(0, b->src, b->size);
  }
  /* This block deliberately has no end-of-stream marker. */
  deflateEnd(&stream);
  return NULL;
}

/* The caller owns the OCaml buffers until every helper has joined. Only
   raw bytes are shared. Each output fits its own fixed-size destination. */
value cvm_pie_deflate(value input, value size, value output, value lengths, value settings, value prior_crc) {
  intnat n = Long_val(size);
  bool production = Wosize_val(settings) == 4;
  if ((!production && Wosize_val(settings) != 3) || !Wosize_val(lengths)) return Val_long(-1);
  intnat width = Long_val(Field(settings, 0)), stride = Long_val(Field(settings, 1));
  intnat level = Long_val(Field(settings, 2));
  if (n < 1 || (uintnat)n > caml_string_length(input) ||
      width < 1 || width > (1<<22) || stride < width || stride > (1<<23) ||
      level < 1 || level > 9 || n > MAX_BLOCKS * width) return Val_long(-1);
  unsigned count = (unsigned)((n + width - 1) / width);
  if (count > Wosize_val(lengths) || (uintnat)(stride * count) > caml_string_length(output))
    return Val_long(-1);
  struct block blocks[MAX_BLOCKS];
  pthread_t threads[MAX_BLOCKS];
  int launched[MAX_BLOCKS] = {0};
  for (unsigned i = 0; i < count; ++i) {
    intnat remain = n - i * width;
    blocks[i] = (struct block){ .src = (Bytef *)Bytes_val(input) + i * width,
      .dst = (Bytef *)Bytes_val(output) + i * stride,
      .size = (unsigned)(remain < width ? remain : width), .capacity = (unsigned)stride,
      .level = (int)level, .production = production,
      .last = production && Long_val(Field(settings, 3)) && i + 1 == count };
    if (i + 1 < count)
      launched[i] = pthread_create(&threads[i], NULL, compress_block, &blocks[i]) == 0;
  }
  for (unsigned i = 0; i < count; ++i)
    if (!launched[i]) compress_block(&blocks[i]);
  for (unsigned i = 0; i < count; ++i)
    if (launched[i]) pthread_join(threads[i], NULL);
  uLong crc = (uLong)Long_val(prior_crc);
  for (unsigned i = 0; i < count; ++i) {
    if (!blocks[i].written) return Val_long(-1);
    Field(lengths, i) = Val_long(blocks[i].written);
    crc = crc32_combine(crc, blocks[i].crc, blocks[i].size);
  }
  return Val_long(crc);
}

value cvm_pie_deflate_byte(value *v, int argc) {
  (void)argc;
  return cvm_pie_deflate(v[0], v[1], v[2], v[3], v[4], v[5]);
}
