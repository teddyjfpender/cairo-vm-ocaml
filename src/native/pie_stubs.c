/* Cairo PIE input: raw-deflate inflation of zip members (zlib) and decoding
   of memory.bin field elements into felt codes (see field.h). */
#include <zlib.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include "field.h"

/* The archive is a read-only file mapping. Only individual uncompressed
   members are copied into the OCaml heap. */
value cvm_pie_stored(value src, value off, value len) {
  CAMLparam1(src);
  CAMLlocal1(dst);
  size_t o = Long_val(off), n = Long_val(len);
  size_t size = Caml_ba_array_val(src)->dim[0];
  if (o > size || n > size - o) caml_failwith("Cairo PIE zip member is truncated");
  dst = caml_alloc_string(n);
  memcpy(Bytes_val(dst), (const unsigned char *)Caml_ba_data_val(src) + o, n);
  CAMLreturn(dst);
}

/* Inflate [clen] raw-deflate bytes of [src] at [off] into a fresh string of
   exactly [ulen] bytes. Fails unless the stream ends with that length. */
value cvm_inflate_raw(value src, value off, value clen, value ulen) {
  CAMLparam1(src);
  CAMLlocal1(dst);
  size_t n = (size_t)Long_val(ulen), m = (size_t)Long_val(clen), o = (size_t)Long_val(off);
  size_t size = Caml_ba_array_val(src)->dim[0];
  if (o > size || m > size - o) caml_failwith("Cairo PIE zip member is truncated");
  dst = caml_alloc_string(n);
  z_stream s;
  memset(&s, 0, sizeof s);
  if (inflateInit2(&s, -MAX_WBITS) != Z_OK) caml_failwith("inflateInit2 failed");
  const unsigned char *in = (const unsigned char *)Caml_ba_data_val(src) + o;
  unsigned char *out = (unsigned char *)Bytes_val(dst);
  size_t done_in = 0, done_out = 0;
  int rc = Z_OK;
  /* zlib counts in uInt: feed and drain in chunks below 4 GiB */
  const size_t chunk = (size_t)1 << 30;
  while (rc == Z_OK) {
    s.next_in = (Bytef *)(in + done_in);
    s.avail_in = (uInt)((m - done_in) < chunk ? (m - done_in) : chunk);
    s.next_out = out + done_out;
    s.avail_out = (uInt)((n - done_out) < chunk ? (n - done_out) : chunk);
    uInt ai = s.avail_in, ao = s.avail_out;
    rc = inflate(&s, Z_NO_FLUSH);
    done_in += ai - s.avail_in;
    done_out += ao - s.avail_out;
    if (rc == Z_BUF_ERROR && done_out < n && done_in < m) rc = Z_OK;
    if (rc == Z_OK && ai == s.avail_in && ao == s.avail_out) break; /* no progress */
  }
  inflateEnd(&s);
  if (rc != Z_STREAM_END || done_out != n) caml_failwith("Cairo PIE zip member does not inflate to its size");
  CAMLreturn(dst);
}

/* The field element in the 32 little-endian bytes of [buf] at [pos],
   reduced modulo p as Felt252::from_bytes_le_slice; big values go to slot
   [dst]. */
intnat cvm_pie_felt(value buf, intnat pos, value pool, intnat dst) {
  u64 x[4];
  memcpy(x, (const unsigned char *)Bytes_val(buf) + pos, 32);
  while (geq_p(x)) sub4(x, x, P);
  return store(pool, x, dst);
}
value cvm_pie_felt_byte(value buf, value pos, value pool, value dst) {
  return Val_long(cvm_pie_felt(buf, Long_val(pos), pool, Long_val(dst)));
}

/* CRC-32 of a byte string (zip member check). */
value cvm_crc32_bytes(value b) {
  size_t n = caml_string_length(b), done = 0;
  uLong c = crc32(0L, Z_NULL, 0);
  const size_t chunk = (size_t)1 << 30;
  while (done < n) {
    size_t k = n - done < chunk ? n - done : chunk;
    c = crc32(c, (const Bytef *)Bytes_val(b) + done, (uInt)k);
    done += k;
  }
  return Val_long((intnat)c);
}

/* Update a stored ZIP member's running checksum for one output chunk. */
value cvm_pie_crc_update(value crc, value bytes, value len) {
  return Val_long(crc32_z(Long_val(crc), (const Bytef *)Bytes_val(bytes), Long_val(len)));
}

/* Load increasing addresses into empty cells of one pre-sized plain segment.
   Stop before any exceptional cell: OCaml handles validation, duplicate
   writes, pool exhaustion and segment transitions with the usual VM rules.
   state = [cell index; next pool slot; highest written offset plus one]. */
value cvm_pie_load_run(value memory, value seg_id, value cells, value pool, value state) {
  const unsigned char *bytes = (const unsigned char *)Bytes_val(memory);
  const size_t count = caml_string_length(memory) / 40;
  const u64 seg = Long_val(seg_id);
  intnat *dst = Caml_ba_data_val(cells);
  const size_t capacity = Caml_ba_array_val(cells)->dim[0];
  const size_t slots = Caml_ba_array_val(pool)->dim[0] / 32;
  size_t i = Long_val(Field(state, 0)), next = Long_val(Field(state, 1));
  size_t hi = Long_val(Field(state, 2));
  for (; i < count && next < slots; ++i) {
    u64 addr, x[4];
    memcpy(&addr, bytes + 40*i, 8);
    size_t off = addr & ((1ULL << 47) - 1);
    if (((addr >> 47) & 0xffff) != seg || off < hi || off >= capacity) break;
    memcpy(x, bytes + 40*i + 8, sizeof x);
    intnat code;
    if (x[3] >> 63) {
      u64 offset = x[0] & ((1ULL << 47) - 1);
      if (offset >= (1ULL << 40)) break;
      code = (((x[0] >> 47) & 0xffff) << 42) | (offset << 2) | 2;
    } else {
      while (geq_p(x)) sub4(x, x, P);
      code = store(pool, x, next);
      next += (code & 3) == 3;
    }
    dst[off] = code;
    hi = off + 1;
  }
  Field(state, 0) = Val_long(i);
  Field(state, 1) = Val_long(next);
  Field(state, 2) = Val_long(hi);
  return Val_unit;
}

/* Merge selected segment offsets before encoding the 16:47 PIE address.
   The high bit is reserved for the address tag. */
static inline int pie_address(intnat seg, uint64_t off, value offsets, intnat merged,
                              uint64_t *packed) {
  if ((uintnat)seg < Wosize_val(offsets)) {
    intnat delta = Long_val(Field(offsets, seg));
    if (delta >= 0) { seg = merged; off += (uintnat)delta; }
  }
  if ((uintnat)seg > UINT16_MAX || off >= (UINT64_C(1) << 47)) return 0;
  *packed = ((uint64_t)seg << 47) | off;
  return 1;
}

/* Advance a cursor across all segments, skipping holes and emitting whole
   40-byte cells. The caller owns the buffer and streams each filled chunk. */
value cvm_pie_encode(value segs, value highs, value count, value pool,
                     value offsets, value cursor, value buffer) {
  intnat seg = Long_val(Field(cursor, 0)), off = Long_val(Field(cursor, 1));
  const intnat merged = Long_val(Field(cursor, 2)), n = Long_val(count);
  const size_t capacity = caml_string_length(buffer) / 40;
  unsigned char *bytes = Bytes_val(buffer);
  size_t emitted = 0;
  for (; seg < n && emitted < capacity; ++seg, off = 0) {
    value array = Field(segs, seg);
    const intnat *cells = Caml_ba_data_val(array);
    const intnat hi = Long_val(Field(highs, seg));
    if (hi < 0 || hi > Caml_ba_array_val(array)->dim[0]) return Val_long(-1);
    if (!hi) continue;
    uint64_t last;
    if (!pie_address(seg, hi-1, offsets, merged, &last)) return Val_long(-1);
    uint64_t base = (last-(uintnat)(hi-1)) | (UINT64_C(1) << 63);
    while (off < hi) {
      intnat code = cells[off];
      if (code) {
        uint64_t addr = base + (uintnat)off, words[4];
        if ((code & 3) == 2) {
          if (!pie_address(code >> 42, ((uintnat)code >> 2) & ((UINT64_C(1) << 40)-1),
                           offsets, merged, &words[0])) return Val_long(-1);
          words[1] = words[2] = 0;
          words[3] = UINT64_C(1) << 63;
        } else load(pool, code, words);
        memcpy(bytes+40*emitted, &addr, 8);
        memcpy(bytes+40*emitted+8, words, 32);
        ++emitted;
      }
      ++off;
      if (emitted == capacity) goto done;
    }
  }
done:
  Field(cursor, 0) = Val_long(seg);
  Field(cursor, 1) = Val_long(off);
  return Val_long(40*emitted);
}

value cvm_pie_encode_byte(value *argv, int argc) {
  (void)argc;
  return cvm_pie_encode(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
}
