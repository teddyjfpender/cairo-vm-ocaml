/* Run common decoded Cairo instructions without returning to OCaml between
   steps. All pointers are borrowed for one bounded, nonallocating call. The
   OCaml runner owns decoding, hints, segment growth and builtin deduction. */
#include "field.h"
#include "trace_encoding.h"

extern intnat cvm_binop(value, intnat, intnat, intnat, intnat);
extern intnat cvm_pedersen(value, intnat, intnat, intnat);
extern intnat cvm_bits(value, intnat);

#define OFFSET_MASK ((INT64_C(1) << 40) - 1)
#define ADDRESS(seg, off) (((intnat)(seg) << 42) | ((off) << 2) | 2)
#define CELLS(ba) ((intnat *)Caml_ba_data_val(ba))
#define CAPACITY(ba) (Caml_ba_array_val(ba)->dim[0])

static inline int fits(intnat offset, intnat length) {
  return (uintnat)offset < (uintnat)length;
}

static inline intnat small_code(intnat n) {
  return (intnat)(((uintnat)n << 2) | 1);
}

static inline intnat offset(intnat code) {
  return (code >> 2) & OFFSET_MASK;
}

/* Negative pointers with no relocation rule retain their segment and
   offset. An active rule can produce another pointer or an integer and
   can overflow, so let the checked OCaml reader handle those operands. */
struct temporary_segments {
  value rules, segments, highs;
  intnat count;
};

static inline int needs_relocation(const struct temporary_segments *temps, intnat code) {
  if (code >= 0 || (code & 3) != 2) return 0;
  if (!temps) return 1;
  uintnat index = -(code >> 42) - 1;
  return index < Wosize_val(temps->rules) && Long_val(Field(temps->rules, index)) != 0;
}

static inline int same_value(value pool, intnat a, intnat b) {
  return a == b || ((a & b & 3) == 3 && eq4(SLOT(pool, a >> 2), SLOT(pool, b >> 2)));
}

static inline void mark_watched(value maps, intnat seg, intnat off) {
  if (seg >= 2 && (uintnat)seg < Wosize_val(maps)) {
    value map = Field(maps, seg);
    if ((uintnat)off < caml_string_length(map)) Bytes_val(map)[off] = 1;
  }
}

/* Invert an ASSERT_EQ only when both known operands support the Stone
   deduction rule. Zero asks the OCaml runner to handle the instruction. */
static intnat inverse_operand(value pool, intnat kind, intnat dst, intnat known,
                              intnat slot, intnat slots) {
  if (!dst || !known) return 0;
  if (kind == 0) return dst;
  if (kind == 1 && (dst & 3) == 2) {
    if ((known & 3) == 2 && (dst >> 42) == (known >> 42))
      return small_code(offset(dst) - offset(known));
    if ((known & 3) == 1) {
      intnat off = offset(dst) - (known >> 2);
      if ((uintnat)off <= OFFSET_MASK)
        return (dst & ~((intnat)OFFSET_MASK << 2)) | (off << 2);
    }
    return 0;
  }
  if (!(dst & known & 1) || kind > 2 || (kind == 2 && known == 1)) return 0;
  if ((dst & 3) == 1 && (known & 3) == 1) {
    intnat x = dst >> 2, y = known >> 2;
    if (kind == 1) {
      intnat v = x-y;
      if (v > -SMALL_BOUND && v < SMALL_BOUND) return small_code(v);
    } else if (x % y == 0) return small_code(x/y);
  }
  if (slot >= slots) return 0;
  return kind == 1 ? arith(pool, 1, dst, known, slot) : cvm_binop(pool, 3, dst, known, slot);
}

#include "poseidon_batch.h"

#define POSE_JOBS 128
#define POSE_COPIES 2048
struct pending_poseidon {
  struct poseidon_job jobs[POSE_JOBS];
  intnat *copies[POSE_COPIES];
  unsigned count, used;
};

/* Nonzero codes with both low bits clear are private to this C invocation.
   Only copies may propagate them. Every live copy is replaced before the
   generic interpreter, hint processor or artifact writer can see memory. */
static inline int pending(intnat v) { return v && (v & 3) == 0; }
static inline void copy_cell(struct pending_poseidon *queue, intnat *cell, intnat v) {
  *cell = v;
  if (queue && pending(v)) queue->copies[queue->used++] = cell;
}

static void queue_poseidon(struct pending_poseidon *q, value pool, const intnat *cells,
                           value cache, intnat base, intnat *slot) {
  struct poseidon_job *job = &q->jobs[q->count];
  job->cache_base = base; job->slot = *slot;
  for (unsigned i = 0; i < 3; i++) {
    load(pool,cells[i],job->input+4*i);
    Field(cache,base+i) = Val_long((q->count*3+i+1) << 2);
  }
  *slot += 3; ++q->count;
}

static void finish_poseidon(struct pending_poseidon *q, value pool, value cache) {
  if (!q->count) return;
  cvm_poseidon_jobs(q->jobs,q->count);
  for (unsigned j = 0; j < q->count; j++) {
    struct poseidon_job *job = &q->jobs[j];
    for (unsigned i = 0; i < 3; i++) {
      intnat v = store(pool, job->output+4*i, job->slot+i);
      job->codes[i] = v;
      Field(cache,job->cache_base+i) = Val_long(v);
    }
  }
  for (unsigned i = 0; i < q->used; i++) {
    intnat *cell = q->copies[i];
    if (pending(*cell)) {
      unsigned pos = ((unsigned)*cell >> 2)-1;
      *cell = q->jobs[pos/3].codes[pos%3];
    }
  }
}

#include "builtin_selection_block.h"

/* Returns the number of completed instructions. State contains pc, ap, fp,
   execution-segment high-water mark, trace length, and next felt-pool slot. */
static inline __attribute__((always_inline))
value batch(value state, value cache, value segs, value flags, value highs,
            value trace, value pool, intnat nsegs, const int tracing, value ped_cache, value watched, value pose_cache, struct pending_poseidon *queue, const struct temporary_segments *temps) {
  const intnat cache_size = Wosize_val(cache);
  if (Wosize_val(state) < 9 || nsegs < 2 || (uintnat)nsegs > Wosize_val(segs) ||
      (uintnat)nsegs > Wosize_val(flags) || (uintnat)nsegs > Wosize_val(highs))
    return Val_int(0);
  intnat pc = Long_val(Field(state, 0)), ap = Long_val(Field(state, 1));
  intnat fp = Long_val(Field(state, 2)), high = Long_val(Field(state, 3));
  intnat used = Long_val(Field(state, 4)), slot = Long_val(Field(state, 5));
  const intnat slots = CAPACITY(pool) / 32;
  intnat code_seg = Wosize_val(state) >= 12 ? Long_val(Field(state, 10)) : 0;
  intnat code_base = Wosize_val(state) >= 12 ? Long_val(Field(state, 11)) : 0;
  if (!fits(code_seg, nsegs)) return Val_int(0);
  value stack_ba = Field(segs, 1), program_ba = Field(segs, code_seg);
  intnat *stack = CELLS(stack_ba), *program = CELLS(program_ba), *entries = CELLS(trace);
  const intnat length = CAPACITY(stack_ba), program_length = CAPACITY(program_ba);
  const intnat trace_length = CAPACITY(trace);
  if (used < 0 || used > trace_length || slot < 0 || slot > slots ||
      high < 0 || high > length || ap < 0 || fp < 0) return Val_int(0);
  intnat last_trace = used;
  int completed = 0, permutations = 0;
  for (; completed < 8192 && fits(pc - code_base, cache_size); ++completed) {
    if (queue && (queue->used > POSE_COPIES-8 || queue->count == POSE_JOBS)) break;
    uint64_t d = Long_val(Field(cache, pc - code_base));
    /* The caller runs the hints of the first pc only. */
    if (d >> 61 && completed) break;
    d &= ~(UINT64_C(1) << 61);
    if (!d || (tracing && used > trace_length - 3)) break;
    intnat next_pc = pc + 1, next_ap = ap, next_fp = fp;
    /* decode_word admits only the Stwo shapes, so flags alone identify the
       canonical RET and CALL rel, whose offsets are fixed. */
    /* Unbias all three offsets together for signed 16-bit address arithmetic. */
    uint64_t offsets = d ^ UINT64_C(0x800080008000);
    const unsigned shape = (d >> 48) & 0xfff;
    /* Push a frame/stack/immediate operand. The compiler uses [fp-1]
       for the otherwise unused op0, which must still be assigned. */
    if ((shape == 0xe0a || shape == 0xe0e || shape == 0xe06) && (uint16_t)d == 0x8000) {
      if (!fits(ap, length) || !fits(fp-1, length) || !stack[fp-1] || needs_relocation(temps, stack[fp-1])) break;
      intnat v;
      if (shape == 0xe06) {
        if (!fits(pc+1, program_length)) break;
        v = program[pc+1]; next_pc = pc+2;
      } else {
        intnat from = (shape == 0xe0a ? fp : ap) + (int16_t)(offsets >> 32);
        if (!fits(from, length) || !stack[from]) goto general;
        v = stack[from];
      }
      if (!v || needs_relocation(temps, v) || needs_relocation(temps, stack[ap]) || (stack[ap] && !same_value(pool, stack[ap], v))) break;
      copy_cell(queue, stack+ap, v); next_ap = ap+1;
      if (next_ap > high) high = next_ap;
      goto complete;
    }
    /* A compiler-generated pointer increment or counter update typically
       writes a fresh cell at ap. Keep the common small immediate entirely in
       registers; preassigned destinations and wider felts need deduction. */
    if ((shape == 0xe14 || shape == 0xe16) && (uint16_t)d == 0x8000) {
      intnat from = (shape == 0xe14 ? ap : fp) + (int16_t)(offsets >> 16);
      if (!fits(ap, length) || !fits(from, length) || !fits(pc+1, program_length)) break;
      intnat a = stack[from], imm = program[pc+1], out;
      if (stack[ap] || (imm & 3) != 1) goto general;
      if ((a & 3) == 1) {
        intnat n = (a >> 2) + (imm >> 2);
        if (n <= -SMALL_BOUND || n >= SMALL_BOUND) goto general;
        out = small_code(n);
      } else if ((a & 3) == 2 && !needs_relocation(temps, a)) {
        intnat off = offset(a) + (imm >> 2);
        if ((uintnat)off > OFFSET_MASK) break;
        out = (a & ~((intnat)OFFSET_MASK << 2)) | (off << 2);
      } else goto general;
      stack[ap] = out;
      next_ap = ap+1; next_pc = pc+2;
      if (next_ap > high) high = next_ap;
      goto complete;
    }
    if (shape == 0x84b) {
      if (fp < 2 || fp > length) break;
      intnat frame = stack[fp-2], ret = stack[fp-1];
      if (needs_relocation(temps, frame) || (frame & 3) != 2 || (ret & 3) != 2 || (ret >> 42) != code_seg) break;
      next_fp = offset(frame); next_pc = offset(ret);
      goto complete;
    }
    if (shape == 0x784) {
      if (!fits(ap, length-1) || !fits(pc+1, program_length)) break;
      intnat rel = program[pc+1], frame = ADDRESS(1,fp), ret = ADDRESS(code_seg,pc+2);
      if ((rel & 3) != 1 || (stack[ap] && stack[ap] != frame) ||
          (stack[ap+1] && stack[ap+1] != ret)) break;
      next_pc = pc+(rel>>2);
      if (next_pc < 0 || next_pc > OFFSET_MASK) break;
      stack[ap] = frame; stack[ap+1] = ret;
      next_ap = next_fp = ap+2;
      if (next_ap > high) high = next_ap;
      goto complete;
    }
general:;
    const unsigned op = (d >> 58) & 3, src = (d >> 50) & 3;
    const unsigned ap_update = (d >> 56) & 3, pc_update = (d >> 54) & 3;
    const unsigned result = (d >> 52) & 3;
    intnat dst_at = ((d & (UINT64_C(1) << 48)) ? fp : ap) + (int16_t)offsets;
    intnat op0_at = ((d & (UINT64_C(1) << 49)) ? fp : ap) + (int16_t)(offsets >> 16);
    if (!fits(dst_at, length) || !fits(op0_at, length)) break;
    intnat dst = stack[dst_at], a = stack[op0_at];
    if (needs_relocation(temps, dst) || needs_relocation(temps, a) || (queue && (pending(dst) || pending(a)))) break;
    int delta = (int16_t)(offsets >> 32);
    if (op == 0) {
      /* Relative conditional jump, unconditional jump and ap += immediate. */
      if (!dst || !a) break;
      intnat imm;
      if (src == 1) {
        if (!fits(pc+1, program_length)) break;
        imm = program[pc+1];
      } else {
        intnat at = (src == 2 ? fp : ap) + delta;
        if (src < 2 || ap_update != 1 || !fits(at, length)) break;
        imm = stack[at];
      }
      if ((imm & 3) != 1) break;
      if (ap_update == 1) {
        if (pc_update || result) break;
        next_ap = ap + (imm>>2); next_pc = pc+1+(src == 1);
      } else {
        next_ap = ap + (ap_update == 2);
        if (pc_update == 3) {
          next_pc=dst==1?pc+2:pc+(imm>>2);
          if(!tracing && !queue && code_seg==0 && d==VALIDATE_FIRST && dst>1 && imm==small_code(4) &&
             Field(cache,pc)==Val_long(VALIDATE_FIRST) && pc+4<cache_size && Field(cache,pc+4)==Val_long(UINT64_C(0x1e0a7ff97fff8000))) {
            int rows=validate_builtins_block(cache,pc,cache_size,pc,program,program_length,
              segs,flags,highs,nsegs,stack,length,ap,fp,pool,watched,temps,8192-completed);
            if(rows) {
              completed+=16*rows-1; next_pc=pc; next_ap=next_fp=ap+15*rows;
              if (fits(next_ap,length) && completed+rows+3<=8192 && stack[next_fp-3]==small_code(0) &&
                  pc+20<cache_size && Field(cache,pc+2)==Val_long(UINT64_C(0x1e0a7ff97fff8000)) &&
                  Field(cache,pc+3)==Val_long(UINT64_C(0x184b7fff7fff7ffe)) &&
                  Field(cache,pc+20)==Val_long(UINT64_C(0x184b7fff7fff7ffe)) &&
                  (!stack[next_ap] || same_value(pool,stack[next_ap],stack[next_fp-7]))) {
                if (!stack[next_ap]) stack[next_ap]=stack[next_fp-7];
                completed+=rows+2; next_ap++; next_fp=fp; next_pc=pc+20;
              }
              if(next_ap>high)high=next_ap;
              goto complete;
            }
          }
        }
        else if (pc_update == 2 && !result) next_pc = pc+(imm>>2);
        else break;
      }
      if (next_ap < 0 || next_ap > OFFSET_MASK || next_pc < 0) break;
    } else {
      if (pc_update || (ap_update != 0 && ap_update != 2)) break;
      intnat b;
      intnat *missing = NULL, missing_at = 0, missing_seg = 1;
      if (src == 1) {
        if (!fits(pc+1, program_length)) break;
        b = program[pc+1]; next_pc = pc+2;
      } else if (src >= 2) {
        intnat at = (src == 2 ? fp : ap) + delta;
        if (!fits(at, length)) break;
        b = stack[at];
        if (!b) { missing = stack+at; missing_at = at; }
      } else {
        if ((a & 3) != 2) break;
        intnat sg = a >> 42, at = offset(a) + delta;
        value ba;
        if (temps && sg < 0) {
          intnat k = -sg - 1;
          if (!fits(k, temps->count) || (uintnat)k >= Wosize_val(temps->segments) ||
              (uintnat)k >= Wosize_val(temps->highs)) break;
          ba = Field(temps->segments, k);
        } else {
          if (!fits(sg, nsegs)) break;
          ba = Field(segs, sg);
        }
        if (!fits(at, CAPACITY(ba))) break;
        intnat *cells = CELLS(ba);
        if (watched && sg >= 0) mark_watched(watched, sg, at);
        b = cells[at];
        if (!b) {
          int kind = temps && sg < 0 ? 0 : Long_val(Field(flags, sg));
          /* VM segment flags 5..9 denote the five deducing builtins.
             Their input cells use ordinary write-once assignment. Only
             output offsets require a builtin-specific computation. */
          static const uint8_t width[] = {5, 3, 6, 16, 7};
          static const uint8_t inputs[] = {2, 2, 3, 8, 5};
          int idx = 0;
          if ((unsigned)(kind-5) < 5) {
            idx = at % width[kind-5];
            if (idx < inputs[kind-5]) kind = 0;
          }
          if (kind == 6) {
            if (dst || result || slot >= slots || !fits(at, Wosize_val(ped_cache))) break;
            intnat x = cells[at-2], y = cells[at-1];
            if (!(x & y & 1)) break;
            intnat previous = Long_val(Field(state, 8));
            if (previous && same_value(pool, x, Long_val(Field(state, 6))) &&
                            same_value(pool, y, Long_val(Field(state, 7)))) b = previous;
            else {
              b = cvm_pedersen(pool, x, y, slot);
              Field(state, 6) = Val_long(x); Field(state, 7) = Val_long(y);
              Field(state, 8) = Val_long(b);
            }
            Field(ped_cache, at) = Val_long(b);
          } else if (kind == 7 && pose_cache) {
            intnat base = at-idx;
            if (dst || result || !fits(base+5, Wosize_val(pose_cache))) break;
            b = Long_val(Field(pose_cache,at));
            if (!b) {
              if (!(cells[base] & cells[base+1] & cells[base+2] & 1) || slot > slots-3) break;
              ++permutations;
              if (queue) queue_poseidon(queue,pool,cells+base,pose_cache,base+3,&slot);
              else cvm_poseidon_codes(pool,cells+base,pose_cache,base+3,&slot);
              b = Long_val(Field(pose_cache,at));
            }
          } else if (kind == 5) {
            /* Complete only the requested cell. Siblings remain holes. */
            if (idx < 2 || slot >= slots || dst || result) break;
            intnat x = cells[at-idx], y = cells[at-idx+1];
            if (!(x & y & 1)) break;
            b = bitwise(pool, idx-2, x, y, slot);
            if (!b) break;
          } else {
            if (kind && kind != 1 && kind != 2) break;
            b = inverse_operand(pool, result, dst, a, slot, slots);
            /* Range-check segments 1 and 2 accept integers below 2^128 and 2^96. */
            if (!b || (kind && !((b & 3) == 1 ? b > 0 :
                (b & 3) == 3 && cvm_bits(pool, b) <= (kind == 1 ? 128 : 96)))) break;
          }
          missing = cells+at; missing_at = at; missing_seg = sg;
        }
      }
      if (needs_relocation(temps, b) || (queue && pending(b) && (result || !a))) break;
      intnat value_code = b;
      if (!a) {
        if (!result || !b || !dst) break;
        a = inverse_operand(pool, result, dst, b, slot, slots);
        if (!a) break;
        missing = stack+op0_at; missing_at = op0_at;
        *missing = a;
        if ((a & 3) == 3 && (a >> 2) == slot) ++slot;
        if (missing_at >= high) high = missing_at+1;
        value_code = dst;
      } else if (missing) {
        if (!b) b = inverse_operand(pool, result, dst, a, slot, slots);
        if (!b) break;
        copy_cell(queue, missing, b);
        if ((b & 3) == 3 && (b >> 2) == slot) ++slot;
        if (missing_seg == 1) { if (missing_at >= high) high = missing_at+1; }
        else {
          value table = temps && missing_seg < 0 ? temps->highs : highs;
          intnat i = temps && missing_seg < 0 ? -missing_seg - 1 : missing_seg;
          if (missing_at >= Long_val(Field(table, i))) Field(table, i) = Val_long(missing_at+1);
        }
        value_code = dst ? dst : b;
      } else if (!b) break;
      else if (result) {
        if (result == 1 && (a & 3) == 2 && (b & 3) == 1) {
          intnat off = offset(a) + (b >> 2);
          if ((uintnat)off > OFFSET_MASK) break;
          value_code = (a & ~((intnat)OFFSET_MASK << 2)) | (off << 2);
        } else if (result == 1 && (b & 3) == 2 && (a & 3) == 1) {
          intnat off = offset(b) + (a >> 2);
          if ((uintnat)off > OFFSET_MASK) break;
          value_code = (b & ~((intnat)OFFSET_MASK << 2)) | (off << 2);
        } else {
          if (!(a & b & 1) || result > 2) break;
          int small = 0;
          if ((a & 3) == 1 && (b & 3) == 1) {
            intnat x = a >> 2, y = b >> 2, n;
            if (result == 1) { n = x+y; small = n > -SMALL_BOUND && n < SMALL_BOUND; }
            else { small = !__builtin_mul_overflow(x, y, &n) && n > -SMALL_BOUND && n < SMALL_BOUND; }
            if (small) value_code = small_code(n);
          }
          if (!small) {
            if (slot >= slots) break;
            value_code = arith(pool, result == 1 ? 0 : 2, a, b, slot);
          }
        }
      }
      if (dst && !same_value(pool, dst, value_code)) break;
      /* A preassigned destination already owns the value. The temporary
         limbs used to verify it can be overwritten by the next operation. */
      if (!dst) {
        if ((value_code & 3) == 3 && (value_code >> 2) == slot) ++slot;
        copy_cell(queue, stack+dst_at, value_code);
        if (dst_at >= high) high = dst_at+1;
      }
      next_ap = ap + (ap_update == 2);
    }
complete:
    if (watched && code_seg >= 2) {
      mark_watched(watched, code_seg, pc);
      if (((d >> 50) & 3) == 1) mark_watched(watched, code_seg, pc+1);
    }
    if (tracing) {
      last_trace = used;
      if (code_seg == 0 && pc < 65536 && (ap | fp) < (1 << 23))
        entries[used++] = ((uint64_t)pc << 47) | (ap << 24) | (fp << 1) | 1;
      else {
        uint64_t word;
        if (trace_pack_dynamic(code_seg, pc, ap, fp, &word)) entries[used++] = word;
        else { entries[used++] = ADDRESS(code_seg, pc); entries[used++] = ap; entries[used++] = fp; }
      }
    }
    pc = next_pc; ap = next_ap; fp = next_fp;
  }
  if (queue) finish_poseidon(queue,pool,pose_cache);
  if (pose_cache && permutations >= 8 && Wosize_val(state) > 12) Field(state,12) = Val_long(1);
  Field(state, 0) = Val_long(pc); Field(state, 1) = Val_long(ap);
  Field(state, 2) = Val_long(fp); Field(state, 3) = Val_long(high);
  Field(state, 4) = Val_long(used); Field(state, 5) = Val_long(slot);
  if (tracing && Wosize_val(state) > 9) Field(state, 9) = Val_long(last_trace);
  return Val_int(completed);
}

value cvm_cpu_batch(value state, value cache, value segs, value flags, value highs,
                    value trace, value pool, value nsegs, value tracing, value ped_cache) {
  return Bool_val(tracing)
    ? batch(state, cache, segs, flags, highs, trace, pool, Long_val(nsegs), 1, ped_cache, 0, 0, NULL, NULL)
    : batch(state, cache, segs, flags, highs, trace, pool, Long_val(nsegs), 0, ped_cache, 0, 0, NULL, NULL);
}

value cvm_cpu_batch_byte(value *argv, int argc) {
  (void)argc;
  return cvm_cpu_batch(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8], argv[9]);
}

value cvm_cpu_batch_watched(value state, value cache, value segs, value flags, value highs,
                            value trace, value pool, value nsegs, value watched, value ped_cache) {
  if (Wosize_val(state) > 14 && Long_val(Field(state, 14)))
    return batch(state, cache, segs, flags, highs, trace, pool, Long_val(nsegs), 1, ped_cache, watched, 0, NULL, NULL);
  return batch(state, cache, segs, flags, highs, trace, pool, Long_val(nsegs), 0, ped_cache, watched, 0, NULL, NULL);
}

value cvm_cpu_batch_watched_byte(value *argv, int argc) {
  (void)argc;
  return cvm_cpu_batch_watched(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
                               argv[6], argv[7], argv[8], argv[9]);
}

/* Keep the larger batch buffer outside the ordinary interpreter stack frame. */
static __attribute__((noinline)) value batch_independent_poseidon(value state,value cache,value segs,value flags,
    value highs,value trace,value pool,value nsegs,value watched,value ped,value pose) {
  struct pending_poseidon queue;
  queue.count = queue.used = 0;
  return batch(state,cache,segs,flags,highs,trace,pool,Long_val(nsegs),0,ped,
               Wosize_val(watched) ? watched : 0,pose,&queue,NULL);
}

value cvm_cpu_batch_poseidon(value state, value cache, value segs, value flags, value highs,
                             value trace, value pool, value nsegs, value watched, value ped, value pose) {
  if (Wosize_val(state) > 14 && Long_val(Field(state, 14)))
    return batch(state, cache, segs, flags, highs, trace, pool, Long_val(nsegs), 1, ped,
                 Wosize_val(watched) ? watched : 0, pose, NULL, NULL);
  if (Wosize_val(state) > 12 && Long_val(Field(state,12)))
    return batch_independent_poseidon(state,cache,segs,flags,highs,trace,pool,nsegs,watched,ped,pose);
  if (Wosize_val(watched))
    return batch(state,cache,segs,flags,highs,trace,pool,Long_val(nsegs),0,ped,watched,pose,NULL,NULL);
  return batch(state,cache,segs,flags,highs,trace,pool,Long_val(nsegs),0,ped,0,pose,NULL,NULL);
}

value cvm_cpu_batch_poseidon_byte(value *v, int argc) {
  (void)argc;
  return cvm_cpu_batch_poseidon(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10]);
}

/* Allocate the deferred Poseidon buffer only for runs which use it. */
static __attribute__((noinline)) value batch_temporary_poseidon(
    value state, value cache, value segs, value flags, value highs, value trace, value pool,
    intnat nsegs, value watched, value ped, value pose, const struct temporary_segments *temps) {
  struct pending_poseidon queue;
  queue.count = queue.used = 0;
  return batch(state, cache, segs, flags, highs, trace, pool, nsegs, 0,
               ped, watched, pose, &queue, temps);
}

value cvm_cpu_batch_temporary(value state, value cache, value segs, value flags, value highs,
    value trace, value pool, value nsegs, value watched, value ped, value pose,
    value segments, value temp_highs, value rules) {
  /* The private primitive receives Cpu.run's 15-word register block. */
  struct temporary_segments temps = {rules, segments, temp_highs, Long_val(Field(state, 13))};

  intnat count = Long_val(nsegs);
  if (!Wosize_val(watched)) watched = 0;
  if (!Wosize_val(pose)) pose = 0;
  if (Long_val(Field(state, 14)))
    return batch(state, cache, segs, flags, highs, trace, pool, count, 1, ped, watched, pose, NULL, &temps);
  if (pose && Long_val(Field(state, 12)))
    return batch_temporary_poseidon(state, cache, segs, flags, highs, trace, pool,
                                   count, watched, ped, pose, &temps);
  return batch(state, cache, segs, flags, highs, trace, pool, count, 0, ped, watched, pose, NULL, &temps);
}

value cvm_cpu_batch_temporary_byte(value *v, int argc) {
  (void)argc;
  return cvm_cpu_batch_temporary(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7],
                                 v[8], v[9], v[10], v[11], v[12], v[13]);
}
