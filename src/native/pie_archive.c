#include <stdbool.h>
#include <stddef.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#ifdef OXC_HAVE_PINNED_ARCHIVE
typedef struct ox_archive ox_archive;
extern int ox_pie_create(const unsigned char *, size_t, ox_archive **);
extern int ox_pie_start(ox_archive *, const unsigned char *, size_t, bool);
extern int ox_pie_append(ox_archive *, const unsigned char *, size_t);
extern int ox_pie_finish(ox_archive *);
extern void ox_pie_drop(ox_archive *);

static value archive_status(int status, const char *operation) {
  if (status > 0) caml_unix_error(status, operation, Nothing);
  return Val_bool(status == 0);
}
#define ARCHIVE(v) (*(ox_archive **)Data_custom_val(v))
static void release(value handle) {
  ox_pie_drop(ARCHIVE(handle));
  ARCHIVE(handle) = NULL;
}
static struct custom_operations archive_operations = {
  .identifier = "oxcairo.pinned_archive",
  .finalize = release,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default,
};
#endif

CAMLprim value cvm_pinned_zip_open(value path) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  CAMLparam1(path);
  CAMLlocal1(handle);
  handle = caml_alloc_custom(&archive_operations, sizeof(ox_archive *), 0, 1);
  ARCHIVE(handle) = NULL;
  int status = ox_pie_create(Bytes_val(path), caml_string_length(path), &ARCHIVE(handle));
  if (status > 0) caml_unix_error(status, "open", path);
  if (status != 0) caml_failwith("Cannot open pinned Cairo PIE archive");
  CAMLreturn(handle);
#else
  (void)path;
  caml_failwith("Rust 3.2 PIE archive support was omitted from this build");
#endif
}

CAMLprim value cvm_pinned_zip_start(value handle, value name, value level_one) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  return archive_status(ox_pie_start(ARCHIVE(handle), Bytes_val(name), caml_string_length(name), Bool_val(level_one)), "zip.start_file");
#else
  return Val_false;
#endif
}
CAMLprim value cvm_pinned_zip_append(value handle, value data, value length) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  intnat n = Long_val(length);
  if (n < 0 || (uintnat)n > caml_string_length(data)) caml_invalid_argument("PIE buffer length");
  return archive_status(ox_pie_append(ARCHIVE(handle), Bytes_val(data), n), "zip.write");
#else
  return Val_false;
#endif
}
CAMLprim value cvm_pinned_zip_finish(value handle) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  return archive_status(ox_pie_finish(ARCHIVE(handle)), "zip.finish");
#else
  return Val_false;
#endif
}
CAMLprim value cvm_pinned_zip_close(value handle) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  release(handle);
#endif
  return Val_unit;
}

CAMLprim value cvm_pie_deflate_range(value input, value len, value last, value output) {
#ifdef OXC_HAVE_PINNED_ARCHIVE
  extern ptrdiff_t ox_pie_deflate_range(const unsigned char *, size_t, bool, unsigned char *, size_t);
  intnat n = Long_val(len);
  if (n < 0 || (uintnat)n > caml_string_length(input)) caml_invalid_argument("PIE range length");
  return Val_long(ox_pie_deflate_range(Bytes_val(input), n, Bool_val(last),
                                      Bytes_val(output), caml_string_length(output)));
#else
  return Val_long(-1);
#endif
}
