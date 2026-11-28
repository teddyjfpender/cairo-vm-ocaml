#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#else
#include <libproc.h>
#include <pthread.h>
#include <sys/event.h>
#endif
#ifdef OXC_HAVE_OPENSSL
#include <openssl/evp.h>
#endif

CAMLprim value cvm_worker_clock(value unit) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) uerror("clock_gettime", Nothing);
  return caml_copy_double(ts.tv_sec + ts.tv_nsec * 1e-9);
}

/* The lock is held across parent and child death until the last inheriting
   descriptor closes. A replacement supervisor cannot race an orphan writer. */
CAMLprim value cvm_worker_lock(value path) {
  int fd = open(String_val(path), O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK, 0600);
  if (fd < 0) uerror("open", path);
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1) {
    close(fd); errno=EINVAL; uerror("lock", path);
  }
  if (flock(fd, LOCK_EX|LOCK_NB)) {
    int saved=errno; close(fd); errno=saved; uerror("flock", path);
  }
  return Val_int(fd);
}

static void cap(int resource, uint64_t limit) {
  struct rlimit r;
  if (getrlimit(resource, &r)) uerror("getrlimit", Nothing);
  if (limit < r.rlim_max) r.rlim_max = limit;
  r.rlim_cur = r.rlim_max;
  if (setrlimit(resource, &r)) uerror("setrlimit", Nothing);
}
#ifdef __APPLE__
/* This thread never enters the OCaml runtime. It is created in the private
   job child only; the resident template remains single-threaded. */
static void *watch_supervisor(void *arg) {
  int fd = (int)(intptr_t)arg;
  struct kevent event;
  int n;
  do { n = kevent(fd, NULL, 0, &event, 1, NULL); } while (n < 0 && errno == EINTR);
  _exit(28);
}
static void bind_supervisor(pid_t parent) {
  int fd = kqueue();
  if (fd < 0) uerror("kqueue", Nothing);
  struct kevent event;
  EV_SET(&event, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  if (kevent(fd, &event, 1, NULL, 0, NULL) < 0 || getppid() != parent) _exit(28);
  pthread_t thread;
  int e = pthread_create(&thread, NULL, watch_supervisor, (void *)(intptr_t)fd);
  if (e != 0) { close(fd); errno = e; uerror("pthread_create", Nothing); }
  pthread_detach(thread);
}
#endif
CAMLprim value cvm_worker_limit(value memory, value files, value size, value wall_ms, value parent) {
#ifdef __linux__
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != Long_val(parent)) _exit(28);
  cap(RLIMIT_AS, Long_val(memory));
  /* A reduced RLIMIT_AS only governs future mappings. Check the mappings
     inherited from the template as well. */
  FILE *statm = fopen("/proc/self/statm", "r");
  if (!statm) uerror("statm", Nothing);
  unsigned long long pages = 0;
  int count = fscanf(statm, "%llu", &pages);
  fclose(statm);
  if (count != 1) { errno = EIO; uerror("statm", Nothing); }
  if (pages > (uint64_t)Long_val(memory) / (uint64_t)sysconf(_SC_PAGESIZE))
    caml_raise_out_of_memory();
#else
  bind_supervisor(Long_val(parent));
#endif
  cap(RLIMIT_NOFILE, Long_val(files));
  cap(RLIMIT_FSIZE, Long_val(size));
  signal(SIGXFSZ, SIG_DFL);
  signal(SIGALRM, SIG_DFL);
  /* Bounds an orphan even when the supervisor disappears on macOS. */
  alarm((unsigned int)((Long_val(wall_ms)+999)/1000 + 1));
  return Val_unit;
}

CAMLprim value cvm_worker_rss(value pid) {
#ifdef __APPLE__
  struct proc_taskinfo info;
  int n = proc_pidinfo(Int_val(pid), PROC_PIDTASKINFO, 0, &info, sizeof info);
  if (n == sizeof info) return Val_long(info.pti_resident_size);
  if (errno != ESRCH) uerror("proc_pidinfo", Nothing);
#endif
  return Val_long(0);
}

/* Release builds already link OpenSSL. The portable OCaml digest fallback
   remains available for unaccelerated source builds. */
CAMLprim value cvm_worker_sha256(value source, value file, value dst) {
#ifdef OXC_HAVE_OPENSSL
  unsigned char digest[32], buf[65536];
  unsigned int len = 0;
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (!ctx) caml_raise_out_of_memory();
  int ok = EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
  if (Is_long(file)) {
    if (ok) ok = EVP_DigestUpdate(ctx, String_val(source), caml_string_length(source));
  } else {
    int fd = Int_val(Field(file,0));
    while (ok) {
      ssize_t n = read(fd, buf, sizeof buf);
      if (n < 0 && errno == EINTR) continue;
      if (n < 0) { int e=errno; EVP_MD_CTX_free(ctx); errno=e; uerror("read", Nothing); }
      if (!n) break;
      ok = EVP_DigestUpdate(ctx, buf, n);
    }
  }
  if (ok) ok = EVP_DigestFinal_ex(ctx,digest,&len);
  EVP_MD_CTX_free(ctx);
  if (!ok || len != 32) caml_failwith("SHA-256 failed");
  memcpy(Bytes_val(dst),digest,32);
  return Val_true;
#else
  return Val_false;
#endif
}
