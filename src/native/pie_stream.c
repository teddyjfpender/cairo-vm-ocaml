/* Iterate a ZIP member in whole Cairo cells. The callback borrows its
   chunk until it returns. The archive is a rooted nonmoving file mapping. */
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <stdint.h>
#include <string.h>
#include <zlib.h>

struct decoder {
  z_stream z;
  const unsigned char *input;
  size_t size, consumed;
  int ended;
};

/* Return the number of bytes produced, or -1 for an invalid stream. */
static int read_part(struct decoder *d, unsigned char *out, unsigned wanted) {
  unsigned written = 0;
  while (written < wanted && !d->ended) {
    size_t remaining = d->size - d->consumed;
    unsigned in = (unsigned)(remaining > (1U<<30) ? (1U<<30) : remaining);
    d->z.next_in = (Bytef *)(d->input+d->consumed);
    d->z.avail_in = in;
    d->z.next_out = out+written;
    d->z.avail_out = wanted-written;
    unsigned capacity = d->z.avail_out;
    int result = inflate(&d->z,Z_NO_FLUSH);
    d->consumed += in-d->z.avail_in;
    written += capacity-d->z.avail_out;
    if (result == Z_STREAM_END) d->ended = 1;
    else if (result != Z_OK || (in == d->z.avail_in && capacity == d->z.avail_out)) return -1;
  }
  return (int)written;
}

value cvm_pie_iter_member(value mapping,value descriptor,value callback) {
  CAMLparam3(mapping,descriptor,callback);
  CAMLlocal3(full,tail,result);
  const size_t chunk = 40*32768;
  size_t start = Long_val(Field(descriptor,0)), compressed = Long_val(Field(descriptor,1));
  size_t length = Long_val(Field(descriptor,2)), size = Caml_ba_array_val(mapping)->dim[0];
  int method = Int_val(Field(descriptor,3));
  if (start > size || compressed > size-start || (method != 0 && method != 8) ||
      (method == 0 && compressed != length)) caml_failwith("Invalid Cairo PIE zip member");
  full = caml_alloc_string(length >= chunk ? chunk : 0);
  tail = caml_alloc_string(length%chunk);
  struct decoder d = {.input=(const unsigned char *)Caml_ba_data_val(mapping)+start,.size=compressed};
  if (method && inflateInit2(&d.z,-MAX_WBITS) != Z_OK) caml_failwith("inflateInit2 failed");
  uLong crc = crc32(0,Z_NULL,0);
  int valid = 1;
  for (size_t offset=0; offset<length;) {
    size_t n = length-offset < chunk ? length-offset : chunk;
    value buf = n==chunk ? full : tail;
    unsigned char *out = (unsigned char *)Bytes_val(buf);
    if (method) {
      if (read_part(&d,out,(unsigned)n) != (int)n) { valid=0; break; }
    } else memcpy(out,d.input+offset,n);
    crc = crc32(crc,out,(unsigned)n);
    result = caml_callback_exn(callback,buf);
    if (Is_exception_result(result)) {
      if (method) inflateEnd(&d.z);
      caml_raise(Extract_exception(result));
    }
    offset += n;
  }
  if (method) {
    unsigned char excess;
    if (!d.ended && read_part(&d,&excess,1) != 0) valid=0;
    if (!d.ended) valid=0;
    inflateEnd(&d.z);
  }
  if (!valid) caml_failwith("Invalid Cairo PIE deflate stream or length");
  CAMLreturn(Val_long(crc));
}
