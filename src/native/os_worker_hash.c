/* A seekless ZIP can be read to its current EOF while the encoder runs. The
   writer callback owns all OCaml objects. The reader owns only its stack,
   digest context and a borrowed descriptor of the private staged inode. */
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <errno.h>
#ifdef OXC_HAVE_OPENSSL
#include <openssl/evp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum state { WRITING, COMPLETE, CANCELLED };

struct hash_job {
  int fd, error;
  _Atomic int state;
  unsigned char digest[32];
};

static void *read_archive(void *arg) {
  struct hash_job *job = arg;
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (ctx == NULL) { job->error = ENOMEM; return NULL; }
  if (!EVP_DigestInit_ex(ctx, EVP_sha256(), NULL)) { job->error = EIO; goto end; }
  unsigned char buf[64 * 1024];
  off_t off = 0;
  for (;;) {
    /* Check COMPLETE before pread so an EOF obtained just before the last
       writer flush cannot terminate the digest prematurely. */
    int state = atomic_load_explicit(&job->state, memory_order_acquire);
    if (state == CANCELLED) break;
    ssize_t n = pread(job->fd, buf, sizeof buf, off);
    if (n < 0) {
      if (errno == EINTR) continue;
      job->error = errno;
      break;
    }
    if (n != 0) {
      if (!EVP_DigestUpdate(ctx, buf, (size_t)n)) { job->error = EIO; break; }
      off += n;
    } else if (state == COMPLETE) {
      unsigned int len;
      if (!EVP_DigestFinal_ex(ctx, job->digest, &len) || len != sizeof job->digest)
        job->error = EIO;
      break;
    } else {
      const struct timespec delay = { .tv_nsec = 500000 };
      nanosleep(&delay, NULL);
    }
  }
end:
  EVP_MD_CTX_free(ctx);
  return NULL;
}
#endif

CAMLprim value cvm_worker_hash_during_write(value fd, value write, value out) {
  CAMLparam3(fd,write,out);
  CAMLlocal1(result);
#ifdef OXC_HAVE_OPENSSL
  struct hash_job job = { .fd = Int_val(fd), .state = WRITING };
  pthread_t thread;
  int started = pthread_create(&thread, NULL, read_archive, &job) == 0;
#endif
  result = caml_callback_exn(write, Val_unit);
#ifdef OXC_HAVE_OPENSSL
  if (started) {
    atomic_store_explicit(&job.state, Is_exception_result(result) ? CANCELLED : COMPLETE,
                          memory_order_release);
    pthread_join(thread, NULL);
  }
#endif
  if (Is_exception_result(result)) caml_raise(Extract_exception(result));
#ifdef OXC_HAVE_OPENSSL
  if (started) {
    if (job.error == ENOMEM) CAMLreturn(Val_false);
    if (job.error != 0) { errno=job.error; uerror("archive digest", Nothing); }
    memcpy(Bytes_val(out),job.digest,sizeof job.digest);
    CAMLreturn(Val_true);
  }
#endif
  CAMLreturn(Val_false);
}
