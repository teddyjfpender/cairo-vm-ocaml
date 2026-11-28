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

On an Apple M4 Max, runtime `9022555` ran 70 native Starknet OS scenarios against the stock Rust sequencer. Across 350 cold comparisons, the median scenario was **3.66× faster** and summed case medians fell from **28.62 s to 2.14 s** (**13.36×**). **19 of 70** scenarios reached 10×. In separate measurements on runtime `f6e37bd`, secure replay of two production OS PIEs reached **15.25×** and **15.95×** against Rust v4. [0.2 performance and qualification](docs/release-0.2.md)

On mainnet block 16,000,001, the VM executed 507,630 steps, including OS hints, in **23.84 ms with OxCairo and 78.85 ms with production Rust** (cold medians). For the complete OS-host job on the same block, the Rust service took **478 ms** and the OxCairo worker with stored PIE transport took **568 ms**. Both produced the same final production ZIP. These local measurements replayed recorded mainnet RPC responses and included preparation, validation and publication in the complete job. [VM timings](https://github.com/teddyjfpender/cairo-vm-ocaml/issues/65#issuecomment-7239477448) · [OS-host timings](https://github.com/teddyjfpender/cairo-vm-ocaml/issues/65#issuecomment-7239132924)

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
| [0.2 qualification](docs/release-0.2.md) | OS scenarios, secure replay, comparison baselines and proof evidence |
| [Getting started](docs/getting-started.md) | install, run, proof mode, library use |
| [Learn](docs/learn/index.md) | how a Cairo VM works and how this one is built, with exercises |
| [Architecture](docs/architecture.md) | module map, data flow, design choices |
| [Parity](docs/parity.md) · [Benchmarks](docs/benchmarks.md) | what matches Rust, and how fast |
| [Contributing](docs/contributing.md) | checks a change must pass |

Preview them locally with `scripts/docs.sh` (needs [uv](https://docs.astral.sh/uv/)), then
open http://127.0.0.1:8000.

## License

Apache-2.0
