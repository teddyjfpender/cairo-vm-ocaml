#ifndef OXCAIRO_PIE_H_INCLUDED
#define OXCAIRO_PIE_H_INCLUDED
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Proposed v1. The shared library owns all memory behind a result. */
typedef struct ox_pie_result_v1 ox_pie_result_v1;
typedef uint32_t ox_status_v1;
#define OX_OK           0u
#define OX_ARGUMENT     1u
#define OX_UNSUPPORTED  2u
#define OX_BUSY         3u
#define OX_FORMAT       4u
#define OX_EXECUTION    5u
#define OX_MISMATCH     6u
#define OX_LIMIT        7u
#define OX_NOMEM        8u
#define OX_INTERNAL     9u
#define OX_ABSENT      10u
#define OX_POISONED    11u

/* Artifact IDs are also mask bits. Trace and memory have no header. */
#define OX_TRACE  1u   /* 3 x u64 LE per row: ap, fp, pc */
#define OX_MEMORY 2u   /* u64 LE address, 32-byte canonical felt LE */
#define OX_PIE    4u   /* regenerated Cairo PIE ZIP, segment-relative memory */
#define OX_PROFILE_VM_3_2_0 1u
#define OX_LAYOUT_ALL_CAIRO 1u
#define OX_LAYOUT_SMALL     2u

typedef struct {
    uint32_t struct_size, profile, layout, outputs;
    uint64_t max_input_bytes, max_inflated_bytes, max_steps;
    uint64_t max_segment_cells, max_output_bytes;
} ox_options_v1;
typedef struct { const uint8_t *ptr; size_t len; } ox_view_v1;
typedef struct { char message[256]; } ox_error_v1;

/* Pure; available before runtime startup. All entry points use the C ABI. */
uint32_t ox_pie_abi_major_v1(void); /* returns 1 */

/* Synchronous, try-admit. opts and out required, err optional. Input and
 * opts borrowed only until return. len > 0 requires readable input. All
 * output storage must be writable and disjoint from inputs/each other.
 * Clears *out first. On success transfers exactly one handle to caller.
 * Errors publish no partial result. err is cleared or NUL-terminated UTF-8.
 * Never return an OCaml exception or unwind across the ABI. */
ox_status_v1 ox_pie_run_v1(const uint8_t *zip, size_t len,
    const ox_options_v1 *opts, ox_pie_result_v1 **out, ox_error_v1 *err);

/* Requires a live result, one artifact ID, writable out. Clears *out first.
 * Success lends read-only bytes until result_free. Empty => {NULL,0}.
 * OX_ABSENT = valid ID omitted in opts. Views never need a free. */
ox_status_v1 ox_pie_view_v1(const ox_pie_result_v1 *result,
    uint32_t artifact, ox_view_v1 *out);

/* NULL is OK. Exactly once per owned handle. Reads may overlap other reads
 * or a later run. Caller synchronizes free against all views and readers. */
void ox_pie_result_free_v1(ox_pie_result_v1 *result);
#ifdef __cplusplus
}
#endif
#endif
