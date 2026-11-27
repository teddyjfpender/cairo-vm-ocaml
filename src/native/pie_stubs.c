/* Cairo PIE input: raw-deflate inflation of zip members (zlib) and decoding
   of memory.bin field elements into felt codes (see field.h). */
#include <zlib.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include "field.h"

/* Inflate [clen] raw-deflate bytes of [src] at [off] into a fresh string of
   exactly [ulen] bytes. Fails unless the stream ends with that length. */
value cvm_inflate_raw(value src, value off, value clen, value ulen) {
  CAMLparam1(src);
  CAMLlocal1(dst);
  size_t n = (size_t)Long_val(ulen), m = (size_t)Long_val(clen), o = (size_t)Long_val(off);
  if (o + m > caml_string_length(src)) caml_failwith("Cairo PIE zip member is truncated");
  dst = caml_alloc_string(n);
  z_stream s;
  memset(&s, 0, sizeof s);
  if (inflateInit2(&s, -MAX_WBITS) != Z_OK) caml_failwith("inflateInit2 failed");
  const unsigned char *in = (const unsigned char *)String_val(src) + o;
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
