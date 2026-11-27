# 🐫⚡ cairo-vm-ocaml

A blazingly fast Cairo VM written in OCaml with [OxCaml](https://oxcaml.org/), and a drop-in
replacement for [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm) v4.0.0.

| | |
| --- | --- |
| 🏎️ **Speed** | 4.2× faster than the Rust CLI on its 17 benchmarks, 10× on Pedersen ([benchmarks](benchmarks.md)) |
| 🎯 **Parity** | byte-identical outputs across the upstream test corpus, 0 mismatches ([parity](parity.md)) |
| 🧾 **Coverage** | execution and proof mode, AIR inputs, PIE, every builtin, dynamic layouts, Stwo opcodes |
| 🧠 **Design** | tagged-immediate values, off-heap memory, batched native steps ([architecture](architecture.md)) |

New here? Start with [Getting started](getting-started.md).
