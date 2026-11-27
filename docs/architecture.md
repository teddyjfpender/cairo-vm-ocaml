# Architecture

This page maps the source tree onto the concepts from the [Learn](learn/index.md) chapters.

## Data flow

```
program.json
   │  Program.load_file          (src/program)   parse, skip debug_info
   ▼
Runner.initialize                (src/runner)    segments, builtins, stack, hints compiled
   │
   ▼
Cpu.run ─────────────► cvm_cpu_batch             (src/native/cpu_kernel.c)  hot loop, 8,192 steps/call
   │   ▲  hints, rare cases     │ builtin inputs
   │   └─ Cpu.step ◄────────────┘
   │        │ Deduce (builtin outputs) · Vm.write (write-once memory) · Hints.* (src/hints)
   ▼
Finalize.end_run                 temp relocation, return values, security checks
   │                              (Resources: proof-mode accounting and padding)
   ▼
Artifacts / Air / Pie            relocation, trace and memory files, AIR inputs, PIE
```

## Modules

| Module | Responsibility | Key types |
| --- | --- | --- |
| `Felt` | value encoding, field arithmetic, typed entry points to the C hash kernels | `t = private int` |
| `Segment` | off-heap Bigarray storage with typed and raw accessors | `seg` |
| `Builtin` | builtin kinds, cell layouts, per-run builtin state | `bkind`, `builtin` |
| `Instruction` | decoding, validation, the v4.0.0 Stwo-shape classifier | packed `int` |
| `Vm` | machine state, write-once memory, temporary segments, value arithmetic | `vm` |
| `Deduce` | builtin auto-deduction with per-instance caches | |
| `Cpu` | the generic step and the run loop that drives the C kernel | |
| `Hintrt` | hint context: `ids` bindings, ap tracking, scopes, monomorphic tables | `ctx`, `dyn` |
| `Hints`, `Hints_*` | native implementations of cairo-lang hints | |
| `Runner`, `Resources`, `Finalize`, `Artifacts` | run phases, proof-mode accounting, end checks, outputs | `Runner.t` |
| `Air`, `Pie`, `Layout` | AIR public/private inputs, Cairo PIE, layout definitions | |

## Design choices

**Correctness first, then speed.** `Cpu.step` is a direct implementation of the semantics: it
follows a formal executable model (in Lean) of the Rust VM. The C kernel handles only
instructions it can complete, and changes nothing when it declines one. Everything else goes
through the step, so the fast tier can't introduce new behaviour.

**Values as immediates.** Tagged ints (chapter 2) mean memory is a flat array of machine words,
the GC has nothing to do, and the C kernel reads OCaml memory directly.

**Types where they are free.** `Felt.t = private int`, typed `Segment` accessors and typed kernel
entry points cost nothing at runtime. Paired benchmarks before and after the change measured no
difference.

**C where it pays.** Field arithmetic (Montgomery multiplication specialised to the Stark prime),
the hash permutations, the batched step loop and the file writers are C. The rest is OCaml.

**Measured, not assumed.** Every performance change is measured with paired, interleaved runs
against a frozen baseline build (`bench/compare_revisions.py`). Every behavioural change is
checked against the Rust CLI with `test/parity.py`.

## Exercises

1. Starting from `bin/main.ml`, find where a hint attached to a `pc` is executed during a run.
   Which part of the loop hands control back to OCaml for it?
2. In `src/core/deduce.ml`, find the cache that keeps the Poseidon builtin from computing the
   same permutation twice when a program reads all three outputs.
3. `Segment.sget` returns `Felt.t` but `Segment.raw_get` returns `int`. Which module uses
   `raw_get`, and why would `sget` be wrong there?
4. Suppose you add a new builtin with 4 cells per instance (2 inputs, 2 outputs). List the modules
   you would change.

<details markdown>
<summary>Solutions</summary>

1. `Runner.run_until_end` calls `Cpu.run`, which calls `Cpu.run_fast`. A cached instruction word
   with the hint bit set makes the C batch stop before that `pc`. `run_fast` runs the compiled
   hint closures in OCaml, then calls the kernel again, which executes the hinted instruction
   itself.
2. Each `builtin` record has a `cache : Felt.t array` indexed by cell offset. `Felt.poseidon`
   returns all three outputs, and `cache_outputs` stores them, so later reads of the other two
   outputs hit the cache.
3. `Cpu.record_trace` writes the trace with `raw_set`, and `Resources.trace_entry` reads it with
   `raw_get`. Trace words are packed register triples, not values. Typing them as `Felt.t`
   would be a lie the type checker can't catch, so the raw accessors make the distinction
   explicit.
4. `Builtin` (kind, name, cell counts), `Deduce` (how outputs are computed), `Runner` and
   `Layout` (segment creation, layout membership and ratios), possibly `Vm` (a write validation
   rule), `Air` (its private-input format), and a C kernel in `src/native` if the function is
   expensive.

</details>
