/* Seven straight-line ASSERT_EQ instructions constrain a pair of u32s to a
   nonnegative word. Match operand forms, not program counters or symbols.
   All writes are deferred until all normal operand constraints are known. */
struct pair_cell {
  intnat *cell, seg, off;
};

static inline int pair_indirect(uint64_t d, intnat at_ap, intnat initial_ap, intnat *stack,
                                value segs, intnat nsegs, struct pair_cell *out) {
  intnat i = at_ap + (int)((d >> 16) & 65535) - 32768;
  if (!fits(i, initial_ap)) return 0;
  intnat pointer = stack[i], sg = pointer >> 42;
  if ((pointer & 3) != 2 || sg < 2 || sg >= nsegs) return 0;
  intnat off = offset(pointer) + (int)((d >> 32) & 65535) - 32768;
  value ba = Field(segs, sg);
  if (!fits(off, CAPACITY(ba))) return 0;
  *out = (struct pair_cell){CELLS(ba) + off, sg, off};
  return 1;
}

static inline int nonnegative_u63(value pool, intnat code, uint64_t *out) {
  if ((code & 3) == 1 && code > 0) {
    *out = code >> 2;
    return 1;
  }
  if ((code & 3) != 3) return 0;
  const u64 *v = SLOT(pool, code >> 2);
  if ((v[1] | v[2] | v[3]) || v[0] > INT64_MAX) return 0;
  *out = v[0];
  return 1;
}

static inline intnat pair_code(value pool, uint64_t word, intnat *slot) {
  if (word < SMALL_BOUND) return small_code(word);
  intnat index = (*slot)++;
  u64 *v = SLOT(pool, index);
  v[0] = word;
  v[1] = v[2] = v[3] = 0;
  return (index << 2) | 3;
}

static __attribute__((noinline)) int u32_pair_block(value cache, intnat pc, const intnat *program,
                                                    intnat program_size, value segs, value flags,
                                                    value highs, intnat nsegs, intnat *stack,
                                                    intnat length, intnat ap, intnat fp, value pool,
                                                    intnat slots, intnat *slot, value watched) {
  if (pc > (intnat)Wosize_val(cache) - 8 || pc > program_size - 8 || ap > length - 5 ||
      !fits(fp, ap) || *slot > slots - 2)
    return 0;
  const value *code = Op_val(cache) + pc;
#define WORD(i) ((uint64_t)Long_val(code[i]))
#define INDIRECT(i, shape) ((WORD(i) & UINT64_C(0xffff00000000ffff)) == UINT64_C(shape))
  /* x = *input; slack + x = [fp]; slack = *range; hi = *upper;
     scaled = hi * 2^32; lo + scaled = x; lo = *lower. */
  if (!INDIRECT(0, 0x1e00000000008000) || WORD(1) != UINT64_C(0x1e1d7fff80008000) ||
      !INDIRECT(2, 0x1c00000000007fff) || !INDIRECT(3, 0x1e00000000008000) ||
      WORD(4) != UINT64_C(0x1e2480017fff8000) || program[pc + 5] != small_code(INT64_C(1) << 32) ||
      WORD(6) != UINT64_C(0x1e1c7fff80007ffc) || !INDIRECT(7, 0x1c00000000007fff))
    return 0;
  if (stack[ap] || stack[ap + 1] || stack[ap + 2] || stack[ap + 3] || stack[ap + 4]) return 0;
  struct pair_cell input, range, upper, lower;
  if (!pair_indirect(WORD(0), ap, ap, stack, segs, nsegs, &input) ||
      !pair_indirect(WORD(2), ap + 2, ap, stack, segs, nsegs, &range) ||
      !pair_indirect(WORD(3), ap + 2, ap, stack, segs, nsegs, &upper) ||
      !pair_indirect(WORD(7), ap + 5, ap, stack, segs, nsegs, &lower))
    return 0;
#undef INDIRECT
#undef WORD
  intnat kind = Long_val(Field(flags, range.seg));
  if ((kind != 1 && kind != 2) || range.seg == input.seg || range.seg == upper.seg ||
      range.seg == lower.seg)
    return 0;
  uint64_t maximum, x;
  if (!nonnegative_u63(pool, stack[fp], &maximum) || !nonnegative_u63(pool, *input.cell, &x) ||
      x > maximum)
    return 0;
  uint64_t high = x >> 32, low = (uint32_t)x, slack = maximum - x;
  if (*upper.cell != small_code(high) || *lower.cell != small_code(low)) return 0;
  if (*range.cell) {
    uint64_t assigned;
    if (!nonnegative_u63(pool, *range.cell, &assigned) || assigned != slack) return 0;
  }
  intnat slack_code = pair_code(pool, slack, slot);
  stack[ap] = *input.cell;
  stack[ap + 1] = slack_code;
  stack[ap + 2] = *upper.cell;
  stack[ap + 3] = pair_code(pool, high << 32, slot);
  stack[ap + 4] = *lower.cell;
  if (!*range.cell) {
    *range.cell = slack_code;
    if (range.off >= Long_val(Field(highs, range.seg)))
      Field(highs, range.seg) = Val_long(range.off + 1);
  }
  if (watched) {
    mark_watched(watched, input.seg, input.off);
    mark_watched(watched, range.seg, range.off);
    mark_watched(watched, upper.seg, upper.off);
    mark_watched(watched, lower.seg, lower.off);
  }
  return 1;
}
