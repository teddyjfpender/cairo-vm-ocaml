# 🧠 Architecture

## Why it's fast

- **One int per value.** Small felts (|v| < 2^59), pointers and empty cells are tagged OCaml
  immediates. Big felts live in an append-only pool of canonical limbs, so equality, pointer
  arithmetic and most additions never touch 256-bit arithmetic or allocate. In the types,
  values are `Felt.t = private int`, which costs nothing and keeps them apart from offsets.
- **Memory off the GC heap.** Segments and the trace are `calloc`-backed Bigarrays: nothing
  for the GC to scan, no write barrier, and untouched capacity is free.
- **Batched native steps.** Up to 8,192 decoded instructions run per call in a non-allocating
  C loop. Hints, new instructions, growing segments and unusual operand patterns drop back to
  OCaml, which implements the full deduction rules. Frame pushes are copied together while
  keeping one trace entry per instruction.
- **Builtins on demand.** The kernel writes builtin inputs directly and computes bitwise
  outputs only when they're read. End-of-run checks compare assigned outputs against their
  deductions.
- **A C kernel where it counts.** Montgomery arithmetic specialised to the Stark prime,
  byte-windowed Pedersen tables, Poseidon (Hades), Keccak-f, EC op, GMP inversion, and binary
  writers for the trace and memory files.
- **Cheap hints.** Hints match by exact code string, as upstream does. `ids` references are
  pre-bound when each hint is compiled, and lookup tables are monomorphic.

## Source layout

| Directory | What lives there |
| --- | --- |
| `src/core` | `Felt` (values), `Segment`, `Builtin`, `Instruction`, `Vm` (memory, value arithmetic), `Deduce` (builtin auto-deduction), `Cpu` (step, fast loop) |
| `src/native` | C kernels: field arithmetic, hashes, EC op, the batched CPU loop, artifact writers |
| `src/extensions` | ecdsa and mod builtins, Blake/QM31 opcode extensions |
| `src/hints` | hint runtime (`Hintrt`), generated code table, implementations |
| `src/program` | compiled-program JSON loading |
| `src/runner` | `Runner`, `Resources` (proof-mode accounting), `Finalize`, `Artifacts`, `Air`, `Pie`, `Layout`, `Cairo_run` |
| `test`, `bench` | parity harness and unit tests; benchmark scripts and raw results |
