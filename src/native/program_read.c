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
  off_t file_first;
};

static void *read_range(void *arg) {
  struct read_range *range = arg;
  size_t pos = range->first;
  while (pos < range->last) {
    size_t count = range->last - pos;
    if (count > 0x10000000)
      count = 0x10000000;
    ssize_t n = pread(range->fd, range->data + pos, count,
                      range->file_first + (off_t)(pos - range->first));
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return NULL;
    pos += (size_t)n;
  }
  range->complete = 1;
  return NULL;
}

static value read_pair(int fd, size_t file_size, size_t first_at,
                       size_t first_len, size_t last_at, size_t last_len) {
  CAMLparam0();
  CAMLlocal2(text, result);
  text = caml_alloc_string(first_len + last_len);
  struct read_range first = {fd, Bytes_val(text), 0, first_len,
                             0,  (off_t)first_at};
  struct read_range last = {
      fd, Bytes_val(text), first_len, first_len + last_len, 0, (off_t)last_at};
  pthread_t worker;
  int spawned = pthread_create(&worker, NULL, read_range, &last) == 0;
  read_range(&first);
  if (spawned)
    pthread_join(worker, NULL);
  else
    read_range(&last);
  char extra;
  ssize_t n;
  do {
    n = pread(fd, &extra, 1, (off_t)file_size);
  } while (n < 0 && errno == EINTR);
  if (!first.complete || !last.complete || n != 0)
    CAMLreturn(Val_none);
  result = caml_alloc_small(1, 0);
  Field(result, 0) = text;
  CAMLreturn(result);
}

CAMLprim value cvm_pread_program(value descriptor, value length) {
  size_t size = Long_val(length);
  return read_pair(Int_val(descriptor), size, 0, size / 2, size / 2,
                   size - size / 2);
}

CAMLprim value cvm_pread_program_sections(value descriptor, value sections) {
  size_t size = Long_val(Field(sections, 0)), a = Long_val(Field(sections, 1)),
         a_len = Long_val(Field(sections, 2)), b = Long_val(Field(sections, 3)),
         b_len = Long_val(Field(sections, 4));
  if (a > size || a_len > size - a || b > size || b_len > size - b ||
      a_len > size - b_len)
    return Val_none;
  return read_pair(Int_val(descriptor), size, a, a_len, b, b_len);
}
