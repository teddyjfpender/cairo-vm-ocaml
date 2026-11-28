/* Iterate a ZIP member in whole Cairo cells. The callback borrows its
   chunk until it returns. The archive is a rooted nonmoving file mapping. */
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
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

enum { chunk_bytes = 40*32768 };

struct pipeline {
  struct decoder decoder;
  pthread_mutex_t lock;
  pthread_cond_t changed;
  pthread_t thread;
  unsigned char *buffers;
  size_t length, filled, taken;
  uLong crc;
  int cancelled, finished, valid;
};

/* The producer only touches native memory. A slot is reusable once its
   bytes have been copied to the rooted OCaml buffer. */
static void *produce(void *arg) {
  struct pipeline *p = arg;
  struct decoder *d = &p->decoder;
  int initialized = inflateInit2(&d->z,-MAX_WBITS) == Z_OK;
  int ok = initialized;
  uLong crc = crc32(0,Z_NULL,0);
  for (size_t offset=0; ok && offset<p->length;) {
    pthread_mutex_lock(&p->lock);
    while (!p->cancelled && p->filled-p->taken == 2)
      pthread_cond_wait(&p->changed,&p->lock);
    int cancelled = p->cancelled;
    size_t slot = p->filled % 2;
    pthread_mutex_unlock(&p->lock);
    if (cancelled) { ok=0; break; }
    unsigned n = (unsigned)(p->length-offset < chunk_bytes ? p->length-offset : chunk_bytes);
    unsigned char *out = p->buffers+slot*chunk_bytes;
    if (read_part(d,out,n) != (int)n) { ok=0; break; }
    crc = crc32(crc,out,n);
    offset += n;
    pthread_mutex_lock(&p->lock);
    ++p->filled;
    pthread_cond_signal(&p->changed);
    pthread_mutex_unlock(&p->lock);
  }
  if (ok && !d->ended) {
    unsigned char excess;
    ok = read_part(d,&excess,1)==0 && d->ended;
  }
  if (initialized) inflateEnd(&d->z);
  pthread_mutex_lock(&p->lock);
  p->crc=crc; p->valid=ok; p->finished=1;
  pthread_cond_signal(&p->changed);
  pthread_mutex_unlock(&p->lock);
  return NULL;
}

static int start_pipeline(struct pipeline *p) {
  p->buffers = malloc(2*chunk_bytes);
  if (!p->buffers) return 0;
  if (pthread_mutex_init(&p->lock,NULL) == 0) {
    if (pthread_cond_init(&p->changed,NULL) == 0) {
      if (pthread_create(&p->thread,NULL,produce,p) == 0) return 1;
      pthread_cond_destroy(&p->changed);
    }
    pthread_mutex_destroy(&p->lock);
  }
  free(p->buffers);
  return 0;
}

static int take_part(struct pipeline *p,unsigned char *out,size_t n) {
  pthread_mutex_lock(&p->lock);
  while (p->taken==p->filled && !p->finished) pthread_cond_wait(&p->changed,&p->lock);
  int available = p->taken!=p->filled;
  if (available) {
    memcpy(out,p->buffers+(p->taken%2)*chunk_bytes,n);
    ++p->taken;
    pthread_cond_signal(&p->changed);
  }
  pthread_mutex_unlock(&p->lock);
  return available;
}

static void join_pipeline(struct pipeline *p,int cancel) {
  if (cancel) {
    pthread_mutex_lock(&p->lock);
    p->cancelled=1;
    pthread_cond_signal(&p->changed);
    pthread_mutex_unlock(&p->lock);
  }
  pthread_join(p->thread,NULL);
  pthread_cond_destroy(&p->changed);
  pthread_mutex_destroy(&p->lock);
  free(p->buffers);
}

value cvm_pie_iter_member(value mapping,value descriptor,value callback) {
  CAMLparam3(mapping,descriptor,callback);
  CAMLlocal3(full,tail,result);
  const size_t chunk = chunk_bytes;
  size_t start = Long_val(Field(descriptor,0)), compressed = Long_val(Field(descriptor,1));
  size_t length = Long_val(Field(descriptor,2)), size = Caml_ba_array_val(mapping)->dim[0];
  int method = Int_val(Field(descriptor,3));
  if (start > size || compressed > size-start || (method != 0 && method != 8) ||
      (method == 0 && compressed != length)) caml_failwith("Invalid Cairo PIE zip member");
  full = caml_alloc_string(length >= chunk ? chunk : 0);
  tail = caml_alloc_string(length%chunk);
  struct decoder d = {.input=(const unsigned char *)Caml_ba_data_val(mapping)+start,.size=compressed};
  struct pipeline pipeline = {.decoder=d,.length=length};
  int parallel = method==8 && length>=8*1024*1024 && Bool_val(Field(descriptor,4)) && start_pipeline(&pipeline);
  if (method && !parallel && inflateInit2(&d.z,-MAX_WBITS) != Z_OK) caml_failwith("inflateInit2 failed");
  uLong crc = crc32(0,Z_NULL,0);
  int valid = 1;
  for (size_t offset=0; offset<length;) {
    size_t n = length-offset < chunk ? length-offset : chunk;
    value buf = n==chunk ? full : tail;
    unsigned char *out = (unsigned char *)Bytes_val(buf);
    if (parallel) {
      if (!take_part(&pipeline,out,n)) { valid=0; break; }
    } else if (method) {
      if (read_part(&d,out,(unsigned)n) != (int)n) { valid=0; break; }
    } else memcpy(out,d.input+offset,n);
    if (!parallel) crc = crc32(crc,out,(unsigned)n);
    result = caml_callback_exn(callback,buf);
    if (Is_exception_result(result)) {
      if (parallel) join_pipeline(&pipeline,1);
      else if (method) inflateEnd(&d.z);
      caml_raise(Extract_exception(result));
    }
    offset += n;
  }
  if (parallel) {
    join_pipeline(&pipeline,!valid);
    valid = valid && pipeline.valid; crc = pipeline.crc;
  } else if (method) {
    unsigned char excess;
    if (!d.ended && read_part(&d,&excess,1) != 0) valid=0;
    if (!d.ended) valid=0;
    inflateEnd(&d.z);
  }
  if (!valid) caml_failwith("Invalid Cairo PIE deflate stream or length");
  CAMLreturn(Val_long(crc));
}
