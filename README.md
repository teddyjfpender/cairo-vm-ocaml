<div align="center">

<!-- 🎨 Logo goes here: drop assets/logo.svg and uncomment the line below. -->
<!-- <img src="assets/logo.svg" alt="cairo-vm-ocaml logo" width="220"> -->

# 🐫⚡ cairo-vm-ocaml

**A blazingly fast Cairo VM, written in OCaml.**

[![OxCaml](https://img.shields.io/badge/built%20with-OxCaml%205.2-ee6a1a?logo=ocaml&logoColor=white)](https://oxcaml.org/)
[![cairo-vm](https://img.shields.io/badge/parity-cairo--vm%20v4.0.0-6b46c1)](docs/parity.md)
[![Corpus](https://img.shields.io/badge/corpus-0%20mismatches-2ea44f)](docs/parity.md)
[![Speed](https://img.shields.io/badge/speed-4.2%C3%97%20vs%20Rust-ff69b4)](docs/benchmarks.md)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

</div>

A drop-in replacement for [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm)'s
`cairo-vm-cli`: same flags, byte-identical outputs, about **4× faster**.

- 🏎️ **Fast:** 4.2× the Rust CLI across its 17 benchmarks, 10× on Pedersen
- 🎯 **Exact:** identical trace, memory, AIR inputs and PIE archives on the upstream corpus
- 🧾 **Complete:** execution and proof mode, every builtin, dynamic layouts, Stwo opcodes

## 🚀 Quick start

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox) && opam install dune zarith yojson
dune build --profile release
_build/default/bin/main.exe program.json --layout all_cairo --print_output
```

## 📚 Docs

| | |
| --- | --- |
| [Getting started](docs/getting-started.md) | install, CLI, proof mode, library use |
| [Benchmarks](docs/benchmarks.md) | per-program numbers and methodology |
| [Parity](docs/parity.md) | what matches Rust, and how we check |
| [Architecture](docs/architecture.md) | why it's fast, source layout |
| [Contributing](docs/contributing.md) | tests, parity runs, perf claims |

Preview them as a site with `scripts/docs.sh`, then open http://127.0.0.1:8000.
It needs [uv](https://docs.astral.sh/uv/) and installs nothing globally.

## 📜 License

Apache-2.0
