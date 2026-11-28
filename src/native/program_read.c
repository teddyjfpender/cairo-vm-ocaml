/* Fill a single OCaml string directly from a large regular file. Parallel
   positional reads can fault in separate pages without an intermediate buffer.
   The allocating domain retains its runtime lock until the worker joins. */
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>

struct read_range {
  int fd;
  unsigned char *data;
  size_t first, last;
  int complete;
};

static void *read_range(void *arg) {
  struct read_range *range = arg;
  size_t pos = range->first;
  while (pos < range->last) {
    size_t count = range->last - pos;
    if (count > 0x10000000) count = 0x10000000;
    ssize_t n = pread(range->fd, range->data + pos, count, (off_t)pos);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NULL;
    pos += (size_t)n;
  }
  range->complete = 1;
  return NULL;
}

CAMLprim value cvm_pread_program(value descriptor, value length) {
  CAMLparam2(descriptor, length);
  CAMLlocal2(text, result);
  size_t size = Long_val(length);
  int fd = Int_val(descriptor);
  text = caml_alloc_string(size);
  struct read_range first = {fd, Bytes_val(text), 0, size / 2, 0};
  struct read_range last = {fd, Bytes_val(text), size / 2, size, 0};
  pthread_t worker;
  int spawned = pthread_create(&worker, NULL, read_range, &last) == 0;
  read_range(&first);
  if (spawned) pthread_join(worker, NULL);
  else read_range(&last);

  /* A file may change length after fstat. The channel remains positioned at
     the start for an ordinary streaming read if the observed size changed. */
  char extra;
  ssize_t n;
  do { n = pread(fd, &extra, 1, (off_t)size); } while (n < 0 && errno == EINTR);
  if (!first.complete || !last.complete || n != 0) CAMLreturn(Val_none);
  result = caml_alloc_small(1, 0);
  Field(result, 0) = text;
  CAMLreturn(result);
}
