/* Checked Cairo compiler block for the recursive selectable-builtin loop.
   Match decoded instructions and their literal operands regardless of program
   address. Every memory check precedes the first write. */
/* Keep the native call bound in sync with Cpu.batch_max. */
#define BATCH_STEPS 8192
#define SELECT_FIRST UINT64_C(0x1c2b800080008000)

/* The mask-free comparisons also reject a hint or stop marker on any interior
   instruction. Literal values live in program memory, not the decoded cache. */
/* inner_select_builtins, word offsets relative to the hint:
    -6  jnz n_builtins, +4             -4  push selected_encodings; ret
    -2  ap += 3                         0  assert choice * choice == choice
     1  assert local_enc = *all_enc     2  assert local_ptr = *all_ptr
     3  jnz choice, +4                  5  jmp +4
     7  assert local_enc = *sel_enc     8  assert local_ptr = *sel_ptr
     9  push all_enc + 1               11  push all_ptr + 1
    13  push sel_enc + choice          14  push sel_ptr + choice
    15  push n_builtins - 1            17  call rel -23
    19  ret
   The base return (-3) and caller return (19) are checked separately when
   the process reaches the base case. */
static int match_selection(value cache, const intnat *program, intnat pc) {
  const value *ins = Op_val(cache) + pc;
#define MATCH_AT(k, v) (ins[k] == Val_long(UINT64_C(v)))
  return MATCH_AT(1, 0x1c0380007ff98001) && MATCH_AT(2, 0x1c0380007ffa8002) &&
         MATCH_AT(3, 0x10f780017fff8000) && program[pc + 4] == small_code(4) &&
         MATCH_AT(5, 0x108780017fff7fff) && program[pc + 6] == small_code(4) &&
         MATCH_AT(7, 0x1c0380007ffb8001) && MATCH_AT(8, 0x1c0380007ffc8002) &&
         MATCH_AT(9, 0x1e1680017ff98000) && program[pc + 10] == small_code(1) &&
         MATCH_AT(11, 0x1e1680017ffa8000) && program[pc + 12] == small_code(1) &&
         MATCH_AT(13, 0x1e1a80007ffb8000) && MATCH_AT(14, 0x1e1a80007ffc8000) &&
         MATCH_AT(15, 0x1e1680017ffd8000) && program[pc + 16] == small_code(-1) &&
         MATCH_AT(17, 0x1784800180018000) && program[pc + 18] == small_code(-23);
#undef MATCH_AT
}

static intnat *plain_slot(value segs, value flags, intnat nsegs, intnat ptr, intnat fp) {
  intnat sg = ptr >> 42, off = offset(ptr);
  if ((ptr & 3) != 2 || sg < 0 || (sg == 1 && off >= fp) || !fits(sg, nsegs) ||
      Long_val(Field(flags, sg)) != 0)
    return NULL;
  value ba = Field(segs, sg);
  return fits(off, CAPACITY(ba)) ? CELLS(ba) + off : NULL;
}

static int select_builtin_block(intnat pc, value segs, value flags, value highs, intnat nsegs,
                                intnat *stack, intnat length, intnat ap, intnat fp, value pool,
                                value watched, int chosen, int implicit_hint) {
  if (fp < 7 || fp > length - 10 || ap != fp + 3) return 0;
  if (implicit_hint && stack[fp] && !same_value(pool, stack[fp], small_code(chosen))) return 0;
  if (!stack[fp - 1] || needs_relocation(NULL, stack[fp - 1])) return 0;
  const intnat n = stack[fp - 3];
  if ((n & 3) != 1 || n <= small_code(0)) return 0;
  intnat ptrs[4], *slots[4], v[2], args[7];
  for (int k = 0; k < 4; ++k) {
    int increment = k < 2 || chosen;
    ptrs[k] = stack[fp - 7 + k];
    if ((ptrs[k] & 3) != 2 || ptrs[k] < 0 || (increment && offset(ptrs[k]) == OFFSET_MASK))
      return 0;
    args[k] = ptrs[k] + 4 * increment;
    if (increment && !(slots[k] = plain_slot(segs, flags, nsegs, ptrs[k], fp))) return 0;
  }
  for (int k = 0; k < 2; ++k) {
    v[k] = *slots[k];
    if (!v[k] || needs_relocation(NULL, v[k])) return 0;
    if (stack[fp + 1 + k] && !same_value(pool, stack[fp + 1 + k], v[k])) return 0;
    if (chosen && *slots[2 + k] && !same_value(pool, *slots[2 + k], v[k])) return 0;
  }
  if (chosen && slots[2] == slots[3] && !same_value(pool, v[0], v[1])) return 0;
  args[4] = n - 4;
  args[5] = ADDRESS(1, fp);
  args[6] = ADDRESS(0, pc + 19);
  for (int k = 0; k < 7; ++k)
    if (stack[ap + k] && !same_value(pool, stack[ap + k], args[k])) return 0;
  if (implicit_hint && !stack[fp]) stack[fp] = small_code(chosen);
  for (int k = 0; k < 2; ++k) {
    if (!stack[fp + 1 + k]) stack[fp + 1 + k] = v[k];
    if (chosen && !*slots[2 + k]) {
      *slots[2 + k] = v[k];
      intnat sg = ptrs[2 + k] >> 42, off = offset(ptrs[2 + k]);
      if (off >= Long_val(Field(highs, sg))) Field(highs, sg) = Val_long(off + 1);
    }
  }
  if (watched)
    for (int k = 0; k < (chosen ? 4 : 2); ++k)
      mark_watched(watched, ptrs[k] >> 42, offset(ptrs[k]));
  for (int k = 0; k < 7; ++k)
    if (!stack[ap + k]) stack[ap + k] = args[k];
  return 11 + chosen;
}

value cvm_selection_rows(value state, value cache, value segs, value flags, value highs, value pool,
                         value nsegs_val, value watched) {
  if (Wosize_val(state) < 17) return Val_int(0);
  intnat nsegs = Long_val(nsegs_val), pc = Long_val(Field(state, 0)),
         ap = Long_val(Field(state, 1)), fp = Long_val(Field(state, 2)),
         high = Long_val(Field(state, 3)), remaining = Long_val(Field(state, 15)), count = 0,
         hints = 0;
  if (nsegs < 2 || (uintnat)nsegs > Wosize_val(segs) || (uintnat)nsegs > Wosize_val(flags) ||
      (uintnat)nsegs > Wosize_val(highs))
    return Val_int(0);
  value code = Field(segs, 0), exec = Field(segs, 1);
  const intnat *program = CELLS(code);
  intnat *stack = CELLS(exec), len = CAPACITY(exec), size = Wosize_val(cache);
  if (pc < 6 || pc > CAPACITY(code) - 19 || pc > size - 18 || fp < 7 || fp > len - 10 ||
      ap != fp + 3 ||
      (uint64_t)Long_val(Field(cache, pc)) != (SELECT_FIRST | (UINT64_C(1) << 61)) ||
      !match_selection(cache, program, pc) ||
      Field(cache, pc - 6) != Val_long(UINT64_C(0x10f780017fff7ffd)) ||
      program[pc - 5] != small_code(4) ||
      Field(cache, pc - 2) != Val_long(UINT64_C(0x110780017fff7fff)) ||
      program[pc - 1] != small_code(3))
    return Val_int(0);
  if (!Wosize_val(watched)) watched = 0;
  /* Cpu.run already executed the first hint. Later rows execute the same
     registered hint, a conditional branch and ap += 3. Defer the hint write
     and scope update until the complete row can commit. */
  intnat initial_fp = fp, rows = 0;
  for (;;) {
    int chosen;
    if (!count) {
      if (stack[fp] != small_code(0) && stack[fp] != small_code(1)) break;
      chosen = stack[fp] == small_code(1);
    } else {
      if (count + 14 > BATCH_STEPS || fp < 7 || fp > len - 10 || stack[fp - 3] <= small_code(0) ||
          (stack[fp - 3] & 3) != 1)
        break;
      chosen = 0;
      if (remaining) {
        intnat *all = plain_slot(segs, flags, nsegs, stack[fp - 7], fp);
        intnat *selected = plain_slot(segs, flags, nsegs, stack[fp - 5], fp);
        if (!all || !selected || !*all || !*selected || needs_relocation(NULL, *all) ||
            needs_relocation(NULL, *selected))
          break;
        chosen = same_value(pool, *all, *selected);
      }
    }
    int implicit = count != 0;
    int result = select_builtin_block(pc, segs, flags, highs, nsegs, stack, len,
                                      ap + (implicit ? 3 : 0), fp, pool, watched, chosen, implicit);
    if (!result) break;
    if (implicit) {
      count += 2;
      hints++;
      remaining -= chosen;
      ap += 3;
    }
    count += result;
    rows++;
    ap += 7;
    fp = ap;
    if (ap > high) high = ap;
  }
  /* Each committed recursive call installed its saved fp and return pc.
     At zero rows remaining, the base case pushes its result and returns
     through exactly those frames. The caller's own return remains pending. */
  intnat next_pc = pc - 6;
  if (rows && fits(ap, len) && count + rows + 2 <= BATCH_STEPS && stack[fp - 3] == small_code(0) &&
      pc + 19 < size && pc + 19 < CAPACITY(code) &&
      Field(cache, pc - 4) == Val_long(UINT64_C(0x1e0a7ffb7fff8000)) &&
      Field(cache, pc - 3) == Val_long(UINT64_C(0x184b7fff7fff7ffe)) &&
      Field(cache, pc + 19) == Val_long(UINT64_C(0x184b7fff7fff7ffe)) &&
      (!stack[ap] || same_value(pool, stack[ap], stack[fp - 5]))) {
    if (!stack[ap]) stack[ap] = stack[fp - 5];
    ++ap;
    if (ap > high) high = ap;
    count += rows + 2;
    fp = initial_fp;
    next_pc = pc + 19;
  }
  if (count) {
    Field(state, 0) = Val_long(next_pc);
    Field(state, 1) = Val_long(ap);
    Field(state, 2) = Val_long(fp);
    Field(state, 3) = Val_long(high);
    Field(state, 15) = Val_long(remaining);
    Field(state, 16) = Val_long(hints);
  }
  return Val_int(count);
}
value cvm_selection_rows_byte(value *v, int argc) {
  (void)argc;
  return cvm_selection_rows(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
}

#define VALIDATE_FIRST UINT64_C(0x10f780017fff7ffd)
#define PUSH_RANGE_CHECK UINT64_C(0x1e0a7ff97fff8000)
#define CAIRO_RETURN UINT64_C(0x184b7fff7fff7ffe)

/* Discriminate the common conditional jump before calling the full matcher.
   An entry marker on a repeated validation row must return to Cpu.run. */
static inline int validation_entry(value cache, intnat pc, intnat size) {
  return fits(pc, size) && pc + 4 < size && Field(cache, pc) == Val_long(VALIDATE_FIRST) &&
         Field(cache, pc + 4) == Val_long(PUSH_RANGE_CHECK);
}

/* Repeated iterations of validate_builtins, including each call to validate_builtin.
   The four source pointers can refer to caller stack data. The range-check
   target is a separate integer segment with the builtin's regular width.
   Word offsets relative to validate_builtins:
    -6  assert start + delta = end     -5  assert width * quotient = delta
    -4  assert *range_check = quotient -3  push range_check + 1; ret
     0  jnz n_builtins, +4              2  push range_check; ret
     4  push range_check                5  push *initial_ptrs
     6  push *final_ptrs                7  push *widths
     8  call rel -14                   10  push initial_ptrs + 1
    12  push final_ptrs + 1            14  push widths + 1
    16  push n_builtins - 1            18  call rel -18
    20  ret
   Offsets 2, 3 and 20 are needed only to unwind a completed recursion. */
static __attribute__((noinline)) int
validate_builtins_block(value cache, intnat pc, intnat cache_size, const intnat *program,
                        intnat program_length, value segs, value flags, value highs, intnat nsegs,
                        intnat *stack, intnat length, intnat ap, intnat fp, value pool,
                        value watched, const struct temporary_segments *temps, int available,
                        intnat *next_pc, intnat *next_ap, intnat *next_fp) {
  const intnat initial_fp = fp;
  if (pc < 6 || pc > cache_size - 19 || pc > program_length - 20 || fp < 7 || ap < fp ||
      ap > length - 15)
    return 0;
  const value *d = Op_val(cache) + pc;
#define AT(k, v) (d[k] == Val_long(UINT64_C(v)))
  if (!(program[pc + 1] == small_code(4) && AT(4, 0x1e0a7ff97fff8000) &&
        AT(5, 0x1e0280007ffa8000) && AT(6, 0x1e0280007ffb8000) && AT(7, 0x1e0280007ffc8000) &&
        AT(8, 0x1784800180018000) && program[pc + 9] == small_code(-14) &&
        AT(-6, 0x1e197ffb80007ffc) && AT(-5, 0x1e287ffd80007fff) && AT(-4, 0x1c0280007ffa7fff) &&
        AT(-3, 0x1e1680017ffa8000) && program[pc - 2] == small_code(1) &&
        AT(-1, 0x184b7fff7fff7ffe) && AT(10, 0x1e1680017ffa8000) &&
        program[pc + 11] == small_code(1) && AT(12, 0x1e1680017ffb8000) &&
        program[pc + 13] == small_code(1) && AT(14, 0x1e1680017ffc8000) &&
        program[pc + 15] == small_code(1) && AT(16, 0x1e1680017ffd8000) &&
        program[pc + 17] == small_code(-1) && AT(18, 0x1784800180018000) &&
        program[pc + 19] == small_code(-18)))
    return 0;
#undef AT
  const intnat n = stack[fp - 3];
  if ((n & 3) != 1 || n <= small_code(0) || !stack[fp - 1] ||
      needs_relocation(temps, stack[fp - 1]))
    return 0;
  intnat rows = n >> 2;
  if (rows > available / 16) rows = available / 16;
  if (rows > (length - ap) / 15) rows = (length - ap) / 15;
  if (rows <= 0) return 0;
  intnat ptrs[4], sg[4], off[4], *slots[4];
  for (int k = 0; k < 4; k++) {
    ptrs[k] = stack[fp - 7 + k];
    if ((ptrs[k] & 3) != 2 || ptrs[k] < 0) return 0;
    sg[k] = ptrs[k] >> 42;
    off[k] = offset(ptrs[k]);
    if (!fits(sg[k], nsegs) || off[k] > OFFSET_MASK - rows) return 0;
    intnat flag = Long_val(Field(flags, sg[k]));
    if (k == 0 ? (sg[k] < 2 || (flag != 1 && flag != 2)) : flag != 0) return 0;
    if (sg[k] == 1 && off[k] + rows > ap) return 0;
    value ba = Field(segs, sg[k]);
    if (off[k] >= CAPACITY(ba)) return 0;
    if (rows > CAPACITY(ba) - off[k]) rows = CAPACITY(ba) - off[k];
    slots[k] = CELLS(ba) + off[k];
  }
  static const intnat empty[15] = {0};
  int count = 0;
  for (; count < rows; count++) {
    intnat start = slots[1][count], finish = slots[2][count], width = slots[3][count], delta;
    if ((width & 3) != 1 || width <= small_code(0)) break;
    if ((start & 3) == 2 && (finish & 3) == 2 && start >= 0 && (start >> 42) == (finish >> 42))
      delta = offset(finish) - offset(start);
    else if ((start & 3) == 1 && (finish & 3) == 1)
      delta = (finish >> 2) - (start >> 2);
    else
      break;
    if (delta < 0 || delta >= SMALL_BOUND || delta % (width >> 2) != 0) break;
    intnat quotient = small_code(delta / (width >> 2));
    if (slots[0][count] && !same_value(pool, slots[0][count], quotient)) break;
    /* The nested call pushes four inputs, its frame and return pc. It writes
       the difference, quotient and advanced range-check pointer. The next
       recursive call adds its remaining arguments and both saved registers. */
    intnat out[15] = {ptrs[0],
                      start,
                      finish,
                      width,
                      ADDRESS(1, fp),
                      ADDRESS(0, pc + 10),
                      small_code(delta),
                      quotient,
                      ptrs[0] + 4,
                      ptrs[1] + 4,
                      ptrs[2] + 4,
                      ptrs[3] + 4,
                      n - 4 * (count + 1),
                      ADDRESS(1, fp),
                      ADDRESS(0, pc + 20)};
    intnat *dst = stack + ap;
    if (!memcmp(dst, empty, sizeof empty))
      memcpy(dst, out, sizeof out);
    else {
      int k = 0;
      for (; k < 15; k++)
        if (dst[k] && !same_value(pool, dst[k], out[k])) break;
      if (k != 15) break;
      for (k = 0; k < 15; k++)
        if (!dst[k]) dst[k] = out[k];
    }
    if (!slots[0][count]) slots[0][count] = quotient;
    for (int k = 0; k < 4; k++) ptrs[k] += 4;
    ap += 15;
    fp = ap;
  }
  if (count) {
    if (off[0] + count > Long_val(Field(highs, sg[0])))
      Field(highs, sg[0]) = Val_long(off[0] + count);
    if (watched)
      for (int k = 0; k < 4; k++) {
        if (sg[k] < 2 || (uintnat)sg[k] >= Wosize_val(watched)) continue;
        value marks = Field(watched, sg[k]);
        intnat mark_length = caml_string_length(marks);
        if (off[k] < mark_length) {
          intnat nmark = mark_length - off[k];
          if (nmark > count) nmark = count;
          memset(Bytes_val(marks) + off[k], 1, nmark);
        }
      }
  }
  if (!count) return 0;
  int steps = 16 * count;
  *next_pc = pc;
  *next_fp = fp;
  /* Base path (test, push, return) plus count - 1 recursive returns. The
     caller's own return is the next pc and is charged by its normal step. */
  if (fits(ap, length) && steps + count + 2 <= available && stack[fp - 3] == small_code(0) &&
      pc + 20 < cache_size && Field(cache, pc + 2) == Val_long(PUSH_RANGE_CHECK) &&
      Field(cache, pc + 3) == Val_long(CAIRO_RETURN) &&
      Field(cache, pc + 20) == Val_long(CAIRO_RETURN) &&
      (!stack[ap] || same_value(pool, stack[ap], stack[fp - 7]))) {
    if (!stack[ap]) stack[ap] = stack[fp - 7];
    ap++;
    steps += count + 2;
    *next_fp = initial_fp;
    *next_pc = pc + 20;
  }
  *next_ap = ap;
  return steps;
}
