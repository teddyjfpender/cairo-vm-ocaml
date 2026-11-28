# OxCairo

OxCairo is a Cairo virtual machine written in OCaml with OxCaml. Its CLI runs Cairo programs, produces execution traces and proof inputs, and replays Cairo PIEs. Version 0.2 also executes the Starknet OS from block witnesses and runs Virtual OS and the block aggregator. [Getting started](getting-started.md)

## What you'll find here

| Section | Read it to |
| --- | --- |
| [0.2 qualification](release-0.2.md) | compare native block execution, secure replay, trace files and proof verification |
| [Getting started](getting-started.md) | build the VM, run programs, use proof mode or the library |
| [Learn](learn/index.md) | understand how a Cairo VM works and how this one is built, with exercises |
| [Architecture](architecture.md) | see the module map, data flow and the reasons it's fast |
| [Parity](parity.md) | see what matches the Rust VM and how that's checked |
| [Benchmarks](benchmarks.md) | see per-program timings and how they were measured |
| [Contributing](contributing.md) | run the checks a change must pass |

## Coverage

- The general VM supports every v4.0.0 layout, including dynamic layouts, plus Blake and QM31 opcode extensions.
- The sequencer checks cover 25 native OS witnesses, four Virtual OS witnesses and 13 aggregator configurations. Independent checks also compare the relocated trace and memory files for seven OS-family workloads. [Parity](parity.md)
- Upstream Stwo verified ten proofs, including direct proof-mode compilations of the OS for genesis and a multiblock witness. [Proof qualification](release-0.2.md)
