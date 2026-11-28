<div align="center">

<img src="docs/assets/logo.png" alt="OxCairo" width="200">

# OxCairo

**A fast Cairo VM written in OCaml with OxCaml.**

[![OxCaml](https://img.shields.io/badge/built%20with-OxCaml%205.2-ee6a1a?logo=ocaml&logoColor=white)](https://oxcaml.org/)
[![cairo-vm](https://img.shields.io/badge/parity-cairo--vm%20v4.0.0-6b46c1)](docs/parity.md)
[![Stwo proofs](https://img.shields.io/badge/Stwo-10%20verified%20proofs-2ea44f)](docs/parity.md)
[![OS benchmarks](https://img.shields.io/badge/Starknet%20OS-benchmarks-ff69b4)](docs/release-0.2.md)
[![Docs](https://img.shields.io/badge/docs-site-ee6a1a)](https://teddyjfpender.github.io/cairo-vm-ocaml/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

</div>

OxCairo runs Cairo programs in execution and proof mode. It supports the Rust Cairo VM v4.0.0 CLI and adds native execution of Starknet OS block witnesses, Virtual OS and the block aggregator. Programs can also replay Cairo PIEs through the CLI, OCaml library or C interface.

At checkpoint `ce19284` on an Apple M4 Max, secure replay of two production OS PIEs exceeded 10× against stock Rust v4.0.0. Native execution of repeated storage writes and short blocks fell below 10×. The qualification report identifies the measured revision for each run, including program loading and requested outputs. [0.2 performance and qualification](docs/release-0.2.md)

## Quick start

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox) && opam install dune zarith yojson
dune build --profile release
_build/default/bin/main.exe program.json --layout all_cairo --print_output
```

## Documentation

The docs are published at **[teddyjfpender.github.io/cairo-vm-ocaml](https://teddyjfpender.github.io/cairo-vm-ocaml/)**.

| | |
| --- | --- |
| [0.2 qualification](docs/release-0.2.md) | end-to-end speed, comparison baselines and proof evidence |
| [Getting started](docs/getting-started.md) | install, run, proof mode, library use |
| [Learn](docs/learn/index.md) | how a Cairo VM works and how this one is built, with exercises |
| [Architecture](docs/architecture.md) | module map, data flow, design choices |
| [Parity](docs/parity.md) · [Benchmarks](docs/benchmarks.md) | what matches Rust, and how fast |
| [Contributing](docs/contributing.md) | checks a change must pass |

Preview them locally with `scripts/docs.sh` (needs [uv](https://docs.astral.sh/uv/)), then
open http://127.0.0.1:8000.

## License

Apache-2.0
