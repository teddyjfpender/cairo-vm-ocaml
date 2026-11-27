#ifndef CVM_POSEIDON_BATCH_H
#define CVM_POSEIDON_BATCH_H

#include "field.h"

/* Each native batch owns these buffers. Workers read and write limbs only.
   The VM thread installs canonical felt codes after joining the workers. */
struct poseidon_job {
  u64 input[12], output[12];
  intnat cache_base, slot, codes[3];
};
void cvm_poseidon_jobs(struct poseidon_job *jobs, unsigned n);
void cvm_poseidon_codes(value pool, const intnat *inputs, value cache, intnat base, intnat *slot);

#endif
