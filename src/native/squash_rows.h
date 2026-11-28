/* Check and materialize consecutive accesses to one dictionary key in
   squash_dict_inner. The first index hint already ran in OCaml. */
value cvm_squash_rows(value regs, value cache, value segs, value flags,
                      value highs, value pool, value nsegs_val, value watched,
                      value remaining, value current_val, value rules,
                      value temp_segments, value ntemp, value trace) {
  struct temporary_segments temps = {rules, temp_segments, Val_unit,
                                     Long_val(ntemp)};
  if (Wosize_val(regs) < 17)
    return Val_int(0);
  intnat pc = Long_val(Field(regs, 0)), ap = Long_val(Field(regs, 1)),
         fp = Long_val(Field(regs, 2));
  intnat nsegs = Long_val(nsegs_val), current = Long_val(current_val);
  if (nsegs < 2 || (uintnat)nsegs > Wosize_val(segs) ||
      (uintnat)nsegs > Wosize_val(flags) ||
      (uintnat)nsegs > Wosize_val(highs) || pc < 0 ||
      (uintnat)(pc + 11) >= Wosize_val(cache) ||
      pc + 12 >= CAPACITY(Field(segs, 0)) || current < 0 || fp < 6 || ap < fp ||
      ap < 3)
    return Val_int(0);
  intnat *stack = CELLS(Field(segs, 1)), len = CAPACITY(Field(segs, 1));
  if (ap > len - 7 || !stack[fp - 1] || needs_relocation(&temps, stack[fp - 1]))
    return Val_int(0);
  /* Cairo PCs relative to squash_dict_inner's access loop:
       0      constrain hinted index_delta_minus1 against *rc
       1,3    materialize delta = minus1 + 1 and stride = 3 * delta
       5      compute next_access from the previous pointer and stride
       6,7,8  constrain its previous value, capture its new value and check key
       9,11   advance rc and branch on the hinted continuation flag
     The original AP layout leaves the continuation at stack[ap+3]. */
  const value *ops = Op_val(cache) + pc;
  const intnat *program = CELLS(Field(segs, 0)) + pc;
#define WORD(i, d) (ops[i] == Val_long(UINT64_C(d)))
  if (!(WORD(0, 0x3e0080007fff8000) && WORD(1, 0x1e1480017fff8000) &&
        program[2] == small_code(1) && WORD(3, 0x1e2480017fff8000) &&
        program[4] == small_code(3) && WORD(5, 0x1e1c7fff7ffb8002) &&
        WORD(6, 0x1c00800180017ff9) && WORD(7, 0x1e00800280018000) &&
        WORD(8, 0x1c01800080007ffa) && WORD(9, 0x1e1480017ffa8001) &&
        program[10] == small_code(1) && WORD(11, 0x32f680017fff7ffd) &&
        program[12] == small_code(-11)))
    return Val_int(0);
#undef WORD
  intnat rc = stack[ap - 1], access = stack[ap - 2], prev = stack[ap - 3],
         key = stack[fp - 6];
  if ((rc & 3) != 2 || (access & 3) != 2 || !prev || !key ||
      needs_relocation(&temps, prev) || needs_relocation(&temps, key))
    return Val_int(0);
  intnat rs = rc >> 42, ds = access >> 42, ro = offset(rc), ao = offset(access);
  if (rs < 2 || !fits(rs, nsegs) || needs_relocation(&temps, access))
    return Val_int(0);
  intnat kind = Long_val(Field(flags, rs));
  if (kind != 1 && kind != 2)
    return Val_int(0);
  value rba = Field(segs, rs), dba;
  if (ds < 0) {
    intnat k = -ds - 1;
    if (!fits(k, temps.count) || (uintnat)k >= Wosize_val(temp_segments))
      return Val_int(0);
    dba = Field(temp_segments, k);
  } else {
    if (!fits(ds, nsegs) || Long_val(Field(flags, ds)) != 0)
      return Val_int(0);
    dba = Field(segs, ds);
  }
  intnat *rcells = CELLS(rba), *dict = CELLS(dba), rlen = CAPACITY(rba),
         dlen = CAPACITY(dba);
  int rows = 0, again = 1;
  intnat initial_ap = ap, initial_ro = ro;
  unsigned char *dmaps = NULL, *rmaps = NULL;
  intnat dw = 0, rw = 0;
  if (ds >= 2 && (uintnat)ds < Wosize_val(watched)) {
    value m = Field(watched, ds);
    dmaps = Bytes_val(m);
    dw = caml_string_length(m);
  }
  if ((uintnat)rs < Wosize_val(watched)) {
    value m = Field(watched, rs);
    rmaps = Bytes_val(m);
    rw = caml_string_length(m);
  }
  struct row_trace buf = {CELLS(trace), Long_val(Field(regs, 4)), CAPACITY(trace)};
  struct row_trace *tr = Long_val(Field(regs, 14)) ? &buf : NULL;
  static const intnat empty[7] = {0};
  while (again && rows < 8192 / 9 && ap <= len - 7 && fits(ro, rlen) &&
         ro < OFFSET_MASK && trace_room(tr, pc + 11, ap + 6, 9)) {
    intnat new_index = current, dm;
    value rest = remaining;
    if (!rows) {
      intnat first = stack[ap];
      if ((first & 3) != 1 || first < small_code(0))
        break;
      dm = first >> 2;
    } else {
      if (rest == Val_emptylist)
        break;
      new_index = Long_val(Field(rest, 0));
      rest = Field(rest, 1);
      if (new_index <= current)
        break;
      dm = new_index - current - 1;
    }
    if (dm >= (OFFSET_MASK - ao) / 3)
      break;
    intnat advance = 3 * (dm + 1), at = ao + advance;
    if (at > dlen - 3 || (ds == 1 && at + 2 >= initial_ap - 3))
      break;
    intnat next = dict[at + 2];
    if (!next || needs_relocation(&temps, next) ||
        !same_value(pool, dict[at], key) ||
        !same_value(pool, dict[at + 1], prev))
      break;
    intnat delta = small_code(dm);
    if (rcells[ro] && !same_value(pool, rcells[ro], delta))
      break;
    int more = rest != Val_emptylist;
    intnat out[7] = {delta,
                     small_code(dm + 1),
                     small_code(advance),
                     small_code(more),
                     next,
                     access + 4 * advance,
                     rc + 4};
    if (!memcmp(stack + ap, empty, sizeof(out))) {
      memcpy(stack + ap, out, sizeof(out));
    } else {
      int i = 0;
      for (; i < 7; i++)
        if (stack[ap + i] && !same_value(pool, stack[ap + i], out[i]))
          break;
      if (i != 7)
        break;
      for (i = 0; i < 7; i++)
        if (!stack[ap + i])
          stack[ap + i] = out[i];
    }
    if (tr) {
      static const char pcs[] = {0, 1, 3, 5, 6, 7, 8, 9, 11};
      static const char aps[] = {0, 1, 2, 3, 4, 4, 5, 5, 6};
      for (unsigned i = 0; i < sizeof(pcs); ++i)
        row_entry(tr, pc + pcs[i], ap + aps[i], fp);
    }
    if (!rcells[ro])
      rcells[ro] = delta;
    if (at < dw)
      memset(dmaps + at, 1, dw - at < 3 ? dw - at : 3);
    current = new_index;
    remaining = rest;
    again = more;
    prev = next;
    access = out[5];
    rc = out[6];
    ao = at;
    ro++;
    ap += 7;
    rows++;
  }
  if (rows) {
    if (initial_ro < rw)
      memset(rmaps + initial_ro, 1, (ro < rw ? ro : rw) - initial_ro);
    Field(regs, 0) = Val_long(again ? pc : pc + 13);
    Field(regs, 1) = Val_long(ap);
    if (ap > Long_val(Field(regs, 3)))
      Field(regs, 3) = Val_long(ap);
    if (ro > Long_val(Field(highs, rs)))
      Field(highs, rs) = Val_long(ro);
    if (tr) {
      Field(regs, 4) = Val_long(tr->used);
      Field(regs, 9) = Val_long(tr->used - 1);
    }
    Field(regs, 15) = Val_long(current);
  }
  return Val_int(rows * 9);
}
value cvm_squash_rows_byte(value *args, int argc) {
  (void)argc;
  return cvm_squash_rows(args[0], args[1], args[2], args[3], args[4], args[5],
                         args[6], args[7], args[8], args[9], args[10], args[11],
                         args[12], args[13]);
}
