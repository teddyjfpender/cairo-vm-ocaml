/* libdeflate encodes a complete raw stream. Use zlib's documented block
   boundary reporting to join these independently compressed pieces into a
   single ZIP member. Only the last block header and its padding change. */
#ifdef OXC_HAVE_LIBDEFLATE
#include <libdeflate.h>

static int append_sync_boundary(Bytef *data, unsigned *length, unsigned capacity,
                                unsigned original_size) {
  z_stream reader = {0};
  if (inflateInit2(&reader, -MAX_WBITS) != Z_OK) return 0;
  reader.next_in = data;
  reader.avail_in = *length;
  size_t header_bit = 0;
  Bytef discarded[32768];
  int complete = 0;
  for (;;) {
    reader.next_out = discarded;
    reader.avail_out = sizeof discarded;
    if (inflate(&reader, Z_BLOCK) != Z_OK) break;
    /* Bit 7 means immediately after a block. The six low bits count
       unused bits in the input consumed so far. Bit 6 marks BFINAL. */
    if (!(reader.data_type & 128)) continue;
    size_t end_bit = reader.total_in * 8 - (reader.data_type & 63);
    if (reader.data_type & 64) {
      size_t aligned = (end_bit + 3 + 7) / 8;
      unsigned used = end_bit % 8;
      if (reader.total_out != original_size || header_bit >= end_bit ||
          aligned + 4 > capacity || !(data[header_bit / 8] & (1U << (header_bit % 8)))) break;
      data[header_bit / 8] &= ~(1U << (header_bit % 8));
      /* Three zero header bits select a non-final stored block. Pad to
         the next byte, then encode LEN=0 and NLEN=65535. */
      size_t byte = end_bit / 8;
      if (used) data[byte++] &= (1U << used) - 1;
      memset(data + byte, 0, aligned - byte);
      memcpy(data + aligned, "\x00\x00\xff\xff", 4);
      *length = (unsigned)aligned + 4;
      complete = 1;
      break;
    }
    header_bit = end_bit;
  }
  inflateEnd(&reader);
  return complete;
}

static int compress_fast(struct block *b) {
  struct libdeflate_compressor *compressor = libdeflate_alloc_compressor(b->level);
  if (!compressor) return 0;
  unsigned size = (unsigned)libdeflate_deflate_compress(compressor, b->src, b->size,
                                                        b->dst, b->capacity - 8);
  libdeflate_free_compressor(compressor);
  if (!size || !append_sync_boundary(b->dst, &size, b->capacity, b->size)) return 0;
  b->written = size;
  b->crc = libdeflate_crc32(0, b->src, b->size);
  return 1;
}
#endif
