# OxCairo 0.3.0

OxCairo 0.3.0 runs a pinned Starknet OS on a prepared JSON or OXW1 witness and produces a Cairo PIE. The resident worker loads the program once, executes each request in a bounded child process, and returns a receipt for the published archive. A node supplies the witness, compiled classes and state. Install the release matching your platform, then follow the [worker protocol](os-host.md) or [generate and replay a PIE in OCaml](pie-walkthrough.md).

## What was qualified

| Surface | Evidence |
| --- | --- |
| Program and hints | Apollo 0.20.0-rc.1, sequencer revision `1860b9850b5c51858c50c0f5038933e49f932eef`. Eight fixtures matched execution and proof-mode artifacts. |
| Proofs | The upstream Stwo verifier accepted direct genesis, Virtual OS and aggregator proofs. The latter two run through the simple bootloader. The release includes all three proofs and their archive checksum. |
| Runtime contracts | The worker checks the program digest, enforces per-job resource limits, and reports typed refusals. Successful stored publication includes a byte count and SHA-256. The execution contract describes the Rust comparison, including partial state after a rejected instruction. |
| Archives | Choose a profile to match a consumer's segment layout and encoding. A canonical content comparison checks four JSON members and every byte of `memory.bin`. An exact ZIP comparison also checks the compressed representation. |

[Release and proof bundle](https://github.com/teddyjfpender/cairo-vm-ocaml/releases/tag/v0.3.0) · [Tagged qualification fixtures and receipts](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/v0.3.0/test/fixtures/programs/apollo-0.20.0-rc.1) · [Execution contract](EXECUTION_CONTRACT.md)

## Warm host measurements

Both engines started with the same prepared witness and pinned OS. The table uses the second request on a warm worker. The Rust reference finished after closing the output. The guarded OxCairo endpoint also hashed, synchronized and atomically published the archive. Each entry uses three paired observations on an Apple M4 Max. Speedups are medians of paired ratios.

| Stored PIE workload | Rust | Guarded OxCairo | Rust / OxCairo |
| --- | ---: | ---: | ---: |
| Mainnet 16,000,001 (2 transactions) | 134 ms | 66 ms | 2.03× |
| Mainnet 16,149,540 (3 transactions) | 352 ms | 154 ms | 2.17× |
| Generated 100 / 500 / 1,000 transfers | 195 / 649 / 1,214 ms | 54 / 164 / 320 ms | 3.66 / 3.94 / 3.89× |
| Generated four blocks of 250 transfers | 1,416 ms | 341 ms | 4.10× |

Timing both in-process workers through file close gave 3.01–3.16× on the two mainnet inputs using stored archives and 1.23–1.26× using byte-identical pinned DEFLATE archives. Charging the caller to encode its already assembled witness gave 1.87–2.09× across repeated and switched real-block inputs on the guarded path. Node witness assembly precedes these timers. The measurements establish neither a tenfold whole-job improvement nor a block-production latency figure. [Paired timings, archive comparisons and raw receipts](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/v0.3.0/bench/results/v0.3.0-m4-max/warm-round-two)

## Running this version

Download and verify the matching platform package using [Getting started](getting-started.md). For the v0.3.0 Linux resident worker, set `OXCAIRO_HOST_MEMORY_BYTES=4294967296` before launch with the default 4 GiB operator ceiling. Adjust this value to match a smaller configured ceiling. This bounds the address space reserved for field elements before the runtime initializes.

In v0.3.0 the single-request host supports `os-host-production`. The resident worker accepts `os-host-standard`, `rust-3.2`, `stored` and `fast-1`. Support for requesting `os-host-production` from the resident worker landed on main after the tag. [Release source](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/v0.3.0) · [Resident worker follow-up](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/99)
