/* Run common decoded Cairo instructions without returning to OCaml between
   steps. All pointers are borrowed for one bounded, nonallocating call. The
   OCaml runner owns decoding, hints, segment growth and builtin deduction. */
#include <stdint.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>

extern intnat cvm_binop(value, intnat, intnat, intnat, intnat);
extern intnat cvm_bitwise(value, intnat, intnat, intnat, intnat);
extern intnat cvm_pedersen(value, intnat, intnat, intnat);
extern intnat cvm_big_eq(value, intnat, intnat);

#define OFFSET_MASK ((INT64_C(1) << 40) - 1)
#define SMALL_BOUND (INT64_C(1) << 59)
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

static inline int same_value(value pool, intnat a, intnat b) {
  return a == b || ((a & b & 3) == 3 && cvm_big_eq(pool, a, b));
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
  return slot < slots ? cvm_binop(pool, kind == 1 ? 1 : 3, dst, known, slot) : 0;
}

/* Returns the number of completed instructions. State contains pc, ap, fp,
   execution-segment high-water mark, trace length, and next felt-pool slot. */
value cvm_cpu_batch(value state, value cache, value segs, value flags, value highs,
                    value trace, value pool, value nsegs_arg, value tracing_arg, value spans, value ped_cache) {
  const intnat cache_size = Wosize_val(cache), nsegs = Long_val(nsegs_arg);
  if (Wosize_val(state) < 9 || nsegs < 2 || (uintnat)nsegs > Wosize_val(segs) ||
      (uintnat)nsegs > Wosize_val(flags) || (uintnat)nsegs > Wosize_val(highs))
    return Val_int(0);
  intnat pc = Long_val(Field(state, 0)), ap = Long_val(Field(state, 1));
  intnat fp = Long_val(Field(state, 2)), high = Long_val(Field(state, 3));
  if (Long_val(Field(highs, 1)) > high) high = Long_val(Field(highs, 1));
  intnat used = Long_val(Field(state, 4)), slot = Long_val(Field(state, 5));
  const intnat slots = caml_string_length(pool) / 32;
  const int tracing = Bool_val(tracing_arg);
  value stack_ba = Field(segs, 1), program_ba = Field(segs, 0);
  intnat *stack = CELLS(stack_ba), *program = CELLS(program_ba), *entries = CELLS(trace);
  const intnat length = CAPACITY(stack_ba), program_length = CAPACITY(program_ba);
  const intnat trace_length = CAPACITY(trace);
  if (used < 0 || used > trace_length || slot < 0 || slot > slots ||
      high < 0 || high > length || ap < 0 || fp < 0) return Val_int(0);
  int completed = 0;
  for (; completed < 8192 && fits(pc, cache_size); ++completed) {
    uint64_t d = Long_val(Field(cache, pc));
    if (!d || d >> 61 || (tracing && used > trace_length - 3)) break;
    intnat next_pc = pc + 1, next_ap = ap, next_fp = fp;
    /* Consecutive frame arguments are pushed one cell per Cairo step.
       A write-once program and its decoded hint bits fix the span. Only
       copy an initialized, disjoint range into fresh stack space. */
    const uint64_t copy_mask = ~UINT64_C(0x0000ffff00000000);
    const uint64_t copy_fp = UINT64_C(0x1e0a00007fff8000);
    if ((d & copy_mask) == copy_fp && fits(pc, Wosize_val(spans)) &&
        ap >= high && fp > 0 && fp <= length && stack[fp-1]) {
      intnat from = fp + (int)((d >> 32) & 65535) - 32768;
      int n = Long_val(Field(spans, pc));
      if (!n) {
        n = 1;
        while (n < 24 && pc+n < cache_size &&
               (uint64_t)Long_val(Field(cache, pc+n)) == d + ((uint64_t)n << 32)) ++n;
        /* A not-yet-decoded successor may extend this span on a later visit. */
        if (n > 1 || (pc+1 < cache_size && Long_val(Field(cache, pc+1)) != 0))
          Field(spans, pc) = Val_int(n);
      }
      if (n > 1 && completed+n <= 8192 && from >= 0 && from+n <= ap &&
          ap <= length-n && (!tracing || (pc+n <= 65536 && (ap+n) < (1<<23) &&
          fp < (1<<23) && used+n <= trace_length))) {
        int ready = 1;
        for (int k=0; k<n; ++k) if (!stack[from+k] || stack[ap+k]) { ready=0; break; }
        if (ready) {
          memcpy(stack+ap, stack+from, (size_t)n * sizeof(*stack));
          if (tracing) for (int k=0; k<n; ++k) {
            entries[used++] = ((uint64_t)(pc+k)<<47) | ((ap+k)<<24) | (fp<<1) | 1;
          }
          pc += n; ap += n; high = ap; completed += n-1;
          continue;
        }
      }
    }
    /* Canonical Cairo CALL and RET account for two frame accesses each.
       These forms use fixed offsets verified by decode_word. */
    if (d == UINT64_C(0x184b7fff7fff7ffe)) {
      if (fp < 2 || fp > length) break;
      intnat frame = stack[fp-2], ret = stack[fp-1];
      if ((frame & 3) != 2 || (ret & 3) != 2 || (ret >> 42) != 0) break;
      next_fp = offset(frame); next_pc = offset(ret);
      goto complete;
    }
    if (d == UINT64_C(0x1784800180018000)) {
      if (!fits(ap, length-1) || !fits(pc+1, program_length)) break;
      intnat rel = program[pc+1], frame = ADDRESS(1,fp), ret = ADDRESS(0,pc+2);
      if ((rel & 3) != 1 || (stack[ap] && stack[ap] != frame) ||
          (stack[ap+1] && stack[ap+1] != ret)) break;
      next_pc = pc+(rel>>2);
      if (!fits(next_pc, cache_size)) break;
      stack[ap] = frame; stack[ap+1] = ret;
      next_ap = next_fp = ap+2;
      if (next_ap > high) high = next_ap;
      goto complete;
    }
    /* Push a frame/stack/immediate operand. The compiler uses [fp-1]
       for the otherwise unused op0, which must still be assigned. */
    const unsigned shape = d >> 48;
    if ((shape == 0x1e0a || shape == 0x1e0e || shape == 0x1e06) &&
        (uint32_t)d == UINT32_C(0x7fff8000)) {
      if (!fits(ap, length) || !fits(fp-1, length) || !stack[fp-1]) break;
      intnat v;
      if (shape == 0x1e06) {
        if (!fits(pc+1, program_length)) break;
        v = program[pc+1]; next_pc = pc+2;
      } else {
        intnat from = (shape == 0x1e0a ? fp : ap) + (int)((d>>32)&65535) - 32768;
        if (!fits(from, length) || !stack[from]) goto general;
        v = stack[from];
      }
      if (!v || (stack[ap] && !same_value(pool, stack[ap], v))) break;
      stack[ap] = v; next_ap = ap+1;
      if (next_ap > high) high = next_ap;
      goto complete;
    }
general:;
    const unsigned op = (d >> 58) & 3, src = (d >> 50) & 3;
    const unsigned ap_update = (d >> 56) & 3, pc_update = (d >> 54) & 3;
    const unsigned result = (d >> 52) & 3;
    intnat dst_at = ((d & (UINT64_C(1) << 48)) ? fp : ap) + (int)(d & 65535) - 32768;
    intnat op0_at = ((d & (UINT64_C(1) << 49)) ? fp : ap) + (int)((d >> 16) & 65535) - 32768;
    if (!fits(dst_at, length) || !fits(op0_at, length)) break;
    intnat dst = stack[dst_at], a = stack[op0_at];
    int delta = (int)((d >> 32) & 65535) - 32768;
    if (op == 1) {
      /* CALL rel immediate. decode_word has already verified the frame slots. */
      if (src != 1 || result != 0 || pc_update != 2 || !fits(pc+1, program_length)) break;
      intnat rel = program[pc+1], ret = ADDRESS(0, pc+2), frame = ADDRESS(1, fp);
      if ((rel & 3) != 1 || (a && a != ret) || (dst && dst != frame)) break;
      next_pc = pc + (rel >> 2);
      if (!fits(next_pc, cache_size)) break;
      stack[dst_at] = frame; stack[op0_at] = ret;
      next_fp = next_ap = ap + 2;
      if (next_ap > high) high = next_ap;
    } else if (op == 2) {
      intnat ret_at = fp + delta;
      if (ap_update || !a || (dst & 3) != 2 || !fits(ret_at, length)) break;
      intnat ret = stack[ret_at];
      if ((ret & 3) != 2 || (ret >> 42) != 0) break;
      next_pc = offset(ret); next_fp = offset(dst);
    } else if (op == 0) {
      /* Relative conditional jump, unconditional jump and ap += immediate. */
      if (src != 1 || !dst || !a || !fits(pc+1, program_length)) break;
      intnat imm = program[pc+1];
      if ((imm & 3) != 1) break;
      if (pc_update == 3 && !ap_update) next_pc = dst == 1 ? pc+2 : pc+(imm>>2);
      else if (pc_update == 2 && !result && !ap_update) next_pc = pc+(imm>>2);
      else if (!pc_update && !result && ap_update == 1) {
        next_ap = ap + (imm>>2); next_pc = pc+2;
      } else break;
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
        if (!fits(sg, nsegs)) break;
        value ba = Field(segs, sg);
        if (!fits(at, CAPACITY(ba))) break;
        intnat *cells = CELLS(ba);
        b = cells[at];
        if (!b) {
          int kind = Long_val(Field(flags, sg));
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
          } else if (kind == 5) {
            /* Complete only the requested cell. Siblings remain holes. */
            if (idx < 2 || slot >= slots || dst || result) break;
            intnat x = cells[at-idx], y = cells[at-idx+1];
            if (!(x & y & 1)) break;
            if ((x & 3) == 1 && (y & 3) == 1 && (x | y) >= 0)
              b = idx == 2 ? x & y : idx == 3 ? (x ^ y) | 1 : x | y;
            else b = cvm_bitwise(pool, idx-2, x, y, slot);
            if (!b) break;
          } else {
            if (kind && kind != 1 && kind != 2) break;
            b = inverse_operand(pool, result, dst, a, slot, slots);
            if (!b || (kind && !(b > 0 && (b & 3) == 1))) break;
          }
          missing = cells+at; missing_at = at; missing_seg = sg;
        }
      }
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
        *missing = b;
        if ((b & 3) == 3 && (b >> 2) == slot) ++slot;
        if (missing_seg == 1) { if (missing_at >= high) high = missing_at+1; }
        else if (missing_at >= Long_val(Field(highs, missing_seg))) Field(highs, missing_seg) = Val_long(missing_at+1);
        value_code = dst ? dst : b;
      } else if (!b) break;
      else if (result) {
        if (result == 1 && (a & 3) == 2 && (b & 3) == 1) {
          intnat off = offset(a) + (b >> 2);
          if ((uintnat)off > OFFSET_MASK) break;
          value_code = (a & ~((intnat)OFFSET_MASK << 2)) | (off << 2);
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
            value_code = cvm_binop(pool, result == 1 ? 0 : 2, a, b, slot);
          }
        }
      }
      if (dst && !same_value(pool, dst, value_code)) break;
      if ((value_code & 3) == 3 && (value_code >> 2) == slot) ++slot;
      if (!dst) { stack[dst_at] = value_code; if (dst_at >= high) high = dst_at+1; }
      next_ap = ap + (ap_update == 2);
    }
complete:
    if (tracing) {
      if (pc < 65536 && (ap | fp) < (1 << 23))
        entries[used++] = ((uint64_t)pc << 47) | (ap << 24) | (fp << 1) | 1;
      else { entries[used++] = ADDRESS(0,pc); entries[used++] = ap; entries[used++] = fp; }
    }
    pc = next_pc; ap = next_ap; fp = next_fp;
  }
  Field(state, 0) = Val_long(pc); Field(state, 1) = Val_long(ap);
  Field(state, 2) = Val_long(fp); Field(state, 3) = Val_long(high);
  Field(state, 4) = Val_long(used); Field(state, 5) = Val_long(slot);
  return Val_int(completed);
}

value cvm_cpu_batch_byte(value *argv, int argc) {
  (void)argc;
  return cvm_cpu_batch(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8], argv[9], argv[10]);
}
