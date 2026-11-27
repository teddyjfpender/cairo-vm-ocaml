# 6. Runs, relocation and proofs

`src/runner/` turns "execute this program" into a sequence of phases. Each phase is a module.

## Initialize (`Runner`)

In execution mode:

1. Segment 0 receives the program's bytecode; segment 1 becomes the execution stack.
2. Each builtin the program declares gets a segment, in the layout's canonical order (output,
   pedersen, range_check, ecdsa, bitwise, ec_op, keccak, poseidon, range_check96, add_mod,
   mul_mod).
3. Two more segments are added: a **return frame** and an **end** segment.
4. The initial stack is the builtin base pointers followed by `return_fp:0` and `end:0`.
   `ap` and `fp` both start just past it, and `pc` is the `main` label.

The run is a loop of [CPU steps](instructions.md) until `pc` equals `end:0`. When `main`
returns, it jumps to that sentinel address.

## Finish (`Finalize`, `Resources`)

- Temporary segments are relocated into real ones.
- Builtin outputs the program wrote are re-checked against their deductions.
- **Return values:** walking back from the final `ap`, each builtin's stop pointer must equal
  the end of the instances it used.
- **Secure-run checks:** no builtin cell past its stop pointer, every used instance has all its
  inputs, and nothing written past the program's code.

## Write outputs (`Artifacts`)

After [relocation](memory.md#relocation-at-the-end-of-a-run), two binary files can be written:

| File | Format |
| --- | --- |
| trace | per step: `ap`, `fp`, `pc` as relocated 64-bit little-endian integers (24 bytes) |
| memory | per assigned cell, in address order: 8-byte address, then the 32-byte little-endian felt |

Both are written by C routines with large buffers. On big programs they run at the
filesystem's write speed.

## Proof mode

A proof-mode program (compiled with `--proof_mode`) starts at `__start__` and ends in an infinite
loop at `__end__`, so the trace can be padded:

1. The stack starts as `[1:2, 0, builtin bases...]` with `fp = 2`, and **every** builtin in the
   layout gets a segment, used or not.
2. After reaching `__end__`, the VM keeps stepping until the trace length is a power of two
   **and** the layout's resource budgets hold. Builtin instances, range-check units, memory units
   and diluted units are all derived from the layout's ratios (`Resources`).
3. Builtin segments are finalized at their allocated sizes, and the public memory (program,
   initial stack, outputs) is recorded.
4. `Air` writes the **AIR public input** (layout, step count, range-check bounds, segment
   addresses, public memory) and the **AIR private input** (paths to the trace and memory files,
   plus each builtin's private witness).

A Cairo **PIE** (`Pie`) is a zip of the run's memory, metadata and resource counts. Another VM can
use it to re-execute or aggregate the run later.

## Exercises

1. A program declares `%builtins output pedersen` and runs with `--layout all_cairo`. List the
   segments and the initial stack. What are `ap` and `fp`?
2. How large is the trace file for a 10,500,008-step run?
3. Write the memory-file record for the relocated address 6 holding the felt 9.
4. Why does proof mode pad the trace to a power of two?
5. In execution mode the stack's last entry is `end:0`. What jumps there, and why does that stop
   the run?

<details markdown>
<summary>Solutions</summary>

1. Segments: 0 program, 1 execution, 2 output, 3 pedersen, 4 return frame, 5 end. Stack:
   `[2:0, 3:0, 4:0, 5:0]`, so `ap = fp = 4` (both in segment 1).
2. `24 × 10,500,008 = 252,000,192` bytes, about 252 MB.
3. `06 00 00 00 00 00 00 00` (address 6), then `09` followed by 31 zero bytes.
4. The prover interpolates the trace over a multiplicative subgroup whose size must be a power
   of two (for FFTs). The layout's resource ratios then need enough steps to cover every
   builtin's usage. The VM keeps stepping in the final loop until both hold.
5. `main`'s final `ret` jumps to the return address the runner placed on the stack, which is
   `end:0`. The run loop stops as soon as `pc` equals that address, before decoding anything
   there.

</details>
