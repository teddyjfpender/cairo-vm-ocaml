# 4. Instructions and the CPU

## Encoding

An instruction is a felt below `2^64` (or, with an opcode extension, below `2^128`). From least
significant bit to most:

| Bits | Field | Values |
| --- | --- | --- |
| 0–15 | `off0` | offset for `dst`, stored as `off + 2^15` |
| 16–31 | `off1` | offset for `op0` |
| 32–47 | `off2` | offset for `op1` |
| 48 | `dst` register | 0 `ap`, 1 `fp` |
| 49 | `op0` register | 0 `ap`, 1 `fp` |
| 50–52 | `op1` source | 0 `[op0 + off2]`, 1 immediate, 2 `fp`, 4 `ap` |
| 53–54 | `res` | 0 `op1`, 1 `op0 + op1`, 2 `op0 * op1` |
| 55–57 | `pc` update | 0 next, 1 absolute jump, 2 relative jump, 4 `jnz` |
| 58–59 | `ap` update | 0 none, 1 `ap += res`, 2 `ap++` |
| 60–62 | opcode | 0 none, 1 `call`, 2 `ret`, 4 `assert_eq` |
| 63+ | extension | 0 Stone, 1 Blake, 2 BlakeFinalize, 3 QM31 |

An immediate operand lives in the next word, so that instruction is two words long.

## Decoding once

`Instruction.decode_word` validates a word with exactly the checks the Rust decoder makes,
then packs the fields into one OCaml int: three biased offsets plus small codes for each flag
group. Instructions in the program segment are decoded once and cached per `pc`, with one bit
of the cached word reserved to say "this pc has hints".

Since v4.0.0 the Rust VM also rejects instructions that have no dedicated Stwo opcode
component. That leaves 16 shapes: `ret`, `ap += x`, relative and absolute jumps, `call`, `jnz`
with an immediate target, the `assert_eq` forms, and the Blake and QM31 extensions.
`Instruction.stwo_supported` is a direct port. It was checked against Rust's classifier on all
130,230 decodable words over the offsets that matter, with no differences.

## Operand deduction

When an operand cell is empty, the VM tries to fill it. The order is fixed, because it decides
which cells get written:

1. **`op0`**: first ask the builtin owning that segment (see [chapter 5](builtins-and-hints.md)).
   Otherwise, for `call` it is the return address `pc + size`. For `assert_eq` with
   `res = op0 + op1` it is `dst - op1`; with `res = op0 * op1` it is `dst / op1` (if
   `op1 ≠ 0`).
2. **`op1`**: builtin first. Otherwise, for `assert_eq` it is `dst` (when `res = op1`),
   `dst - op0` or `dst / op0`.
3. **`dst`**: for `assert_eq` it is `res`; for `call` it is the old `fp`.

Deduced cells are written in the order `op0`, `op1`, `dst`. Arithmetic follows Rust's
`MaybeRelocatable` rules: pointer plus felt is a pointer, pointer minus pointer (same segment) is
a felt, and multiplying a pointer is an error.

## Three execution tiers

The same semantics run at three speeds:

| Tier | Where | Handles |
| --- | --- | --- |
| Native batch | `src/native/cpu_kernel.c` | up to 8,192 cached instructions per call, including common builtin inputs; stops at hints, uncached code, segment growth or unusual operands |
| Fast path | `Cpu.run_fast` (OCaml) | an instruction whose operands are present, or whose only missing cell is the usual `dst`/`[ap]` |
| Generic step | `Cpu.step` | everything else: full deduction, extensions, temporary segments, error reporting |

The fast paths make no state change until they know they can finish the instruction. Anything
unusual falls through to the generic step, which is the reference implementation. That's why
the tiers can't disagree.

## Exercises

1. Decode `0x480680017fff8000`. What Cairo instruction is it, and is it Stwo-supported?
2. Decode `0x208b7fff7fff7ffe` and `0x1104800180018000`.
3. `[ap] = [ap - 2] + [ap - 1]; ap++` runs with `[ap]` empty, `[ap-2] = 3` and `[ap-1] = 4`.
   Which cell is deduced, and to what?
4. `[fp - 3] = [ap] + 5` runs with `[ap]` empty and `[fp - 3] = 12`. Which operand is missing,
   and what is deduced?
5. Is `jmp rel [ap - 1] if [ap - 2] != 0` executable in v4.0.0?
6. Why must the fast paths finish an instruction or change nothing at all?

<details markdown>
<summary>Solutions</summary>

1. The offsets are `0, -1, 1` (`0x8000`, `0x7fff`, `0x8001`) and the flags `0x4806`: `dst` is
   `ap`, `op0` is `fp`, `op1` is an immediate, `res = op1`, `ap++`, `assert_eq`. That's
   `[ap] = imm; ap++`, the "push a constant" instruction. It matches the AssertEqImm shape
   (`off1 = -1`, `op0 = fp`, immediate at `off2 = 1`), so it is supported.
2. `0x208b7fff7fff7ffe` has offsets `-2, -1, -1` and flags `0x208b`: `dst`/`op0`/`op1` all on
   `fp`, `res = op1`, absolute jump, `ret`. That's `ret` (jump to `[fp - 1]`, restore `fp` from
   `[fp - 2]`).
   `0x1104800180018000` has offsets `0, 1, 1` and flags `0x1104`: immediate `op1`, relative jump,
   `call`. That's `call rel imm`: it writes the old `fp` to `[ap]` and the return pc to
   `[ap + 1]`.
3. `dst = [ap]` is missing, so it is deduced as `res = 3 + 4 = 7`, and `ap` advances.
4. `op0 = [ap]` is missing (`op1` is the immediate 5). For `assert_eq` with addition,
   `op0 = dst - op1 = 12 - 5 = 7`, so `[ap]` becomes 7.
5. No. The only `jnz` shape with a Stwo component takes an immediate target (`off2 = 1`), so
   v4.0.0 rejects this with `Unsupported generic instruction`, and so does this VM.
6. If a fast path changed registers or memory and then gave up, the generic step would rerun
   the instruction from a modified state and could deduce different cells or report a different
   error. Finishing completely or leaving no trace keeps one source of truth.

</details>
