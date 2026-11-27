#ifndef OXCAIRO_H
#define OXCAIRO_H

#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Secure PIE replay. NULL layout selects all_cairo. NULL artifact paths
 * omit those outputs. Returns 0 on success and 1 on error, optionally
 * copying a NUL-terminated diagnostic into error[0..error_size).
 * Standalone embedding: the library owns the OCaml runtime. Call from
 * the same OS thread for the life of the process. */
int oxcairo_replay_v1(const char *input, const char *layout, const char *trace,
                      const char *memory, const char *output,
                      char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
#endif
