# cairo-vm-ocaml

A Cairo virtual machine written in OCaml with [OxCaml](https://oxcaml.org/). It is a drop-in
replacement for the `cairo-vm-cli` of [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm)
v4.0.0: same flags, byte-identical outputs, about four times faster.

## What you'll find here

| Section | Read it to |
| --- | --- |
| [Getting started](getting-started.md) | build the VM, run programs, use proof mode or the library |
| [Learn](learn/index.md) | understand how a Cairo VM works and how this one is built, with exercises |
| [Architecture](architecture.md) | see the module map, data flow and the reasons it's fast |
| [Parity](parity.md) | see what matches the Rust VM and how that's checked |
| [Benchmarks](benchmarks.md) | see per-program timings and how they were measured |
| [Contributing](contributing.md) | run the checks a change must pass |

## At a glance

- **Speed:** 4.2× the Rust CLI on its 17 benchmarks; 10× on the Pedersen benchmark.
- **Parity:** across the upstream test corpus, every output (stdout, trace, memory, AIR
  inputs, PIE archives) is identical, in execution and proof mode.
- **Coverage:** every builtin, every v4.0.0 layout including `dynamic`, and the Blake and
  QM31 opcode extensions.
- **Design:** values are tagged immediates typed as `Felt.t = private int`, memory lives
  off the GC heap, and hot instruction sequences run in batches in a small C kernel.
