# OxCairo 0.2.0 release measurements

The tables in this directory record runtime checkpoint `e559436`. Later changes have separate measurements in subdirectories. All times are elapsed seconds on an Apple M4 Max with 36 GiB of physical memory. Each pair runs the two engines sequentially. Other local work also used this machine. The timing tables use the median of paired ratios. Total-suite speedup divides the sum of the Rust case medians by the sum of the OCaml case medians. The per-program mean gives each program equal weight. A sampled peak of zero means the process ended before the first RSS sample.

| File | Work and comparison |
| --- | --- |
| `native-cold.csv` | Four- or five-block native Starknet OS workloads. The stock Rust rows call the pinned sequencer's public API. The verified rows use its native hint processor and checked output diagnostic. |
| `strk-cold.csv` | Four-block STRK token transfers. Transfer count, distinct recipients, Cairo steps and Rust API appear on each row. |
| `reverts-cold.csv` | Successful storage writes interleaved with deliberately reverted transactions against Cairo 0 and Cairo 1 contracts. |
| `related-cold.csv` | Virtual OS nested multicalls and aggregator block chains or state diffs. Output and PIE modes use separate rows. The comparison checks blob sidecars when present. |
| `native-trace-memory.csv` | Fresh secure runs through the Rust and OCaml native hint processors with binary trace and memory emission. One row per engine, including artifact length in rows or cells and SHA-256. |
| `workers.csv` | Fresh VMs in warmed worker processes. Both workers parse the entire witness each time. The OS uses the checked Rust runner. Virtual OS and the aggregator use stock Rust. Each measurement block starts with an untimed request. |
| `sequencer-corpus.csv`, `sequencer-corpus-warm.csv` | The same 70 deterministic upstream scenarios compared with stock Rust, cold and warm. |
| `short-startup.csv` | Cold Rust-independent A/B pairs comparing the OCaml compiler JSON and its packed representation. One-time packing is outside the timed runs. |
| `bootloader.csv` | Production OS archives inside the upstream simple bootloader. Four modes cross trace padding with artifact emission. All runs check printed output and fact topology. Artifact runs also check the full trace and memory. |
| `direct-replay.csv`, `pie-artifacts.json` | Secure production archive replay. Fresh Rust v4 timings cover the archives that fit the memory budget. Full artifact receipts identify each input and engine. |
| `previous-replay.csv` | The earlier OCaml `feat/os-pie` executable and the release executable on the same four archives. |
| `generic-execution.csv`, `generic-traced.csv` | Rust v4 CLI against the release on 17 generic benchmarks. |
| `previous-generic-exec.csv`, `previous-generic-traced.csv` | Starting OCaml main against the release on the same 17 programs. |
| `traced-kernel-ab.csv` | Matched execution before and after trace-path changes on five workloads. Both executables emit full trace and memory. |
| `prover-inputs.txt` | SHA-256 of the ten complete Stwo prover inputs regenerated from this checkpoint. |
| `manifest.json` | Compiler program sizes and SHA-256 digests, reference revisions, binary digests and host information. |

Cold native comparisons supply the full compiler image to OCaml, including debug information. The harness checks that the identical bytes occur in the Rust executable. For native output, stock Rust also constructs a relocated image and a PIE. The checked diagnostic runs the same hints, VM end checks, auto-deductions and return-value checks and emits the public words. A separate streaming Rust reference produced the archive-member oracles for the largest inputs. The fixture checks also cover normalized public output and all five decompressed PIE members. ZIP envelope metadata and compression streams can differ.

The large native witnesses were produced by the pinned sequencer and Blockifier harness. The four production archives are independent historical replay inputs. Reconstructing a native run from the original production witnesses would require the corresponding block inputs.

## Reproduction

Build the CLI, prepared worker and optional C library using `scripts/build_pgo.py`. Its default training witnesses are independent of the large held-out rows. Build the Rust examples from `bench/reference` and the wrappers in `bench` against the sequencer revision in the manifest. Use the exported compiler images from that build. The production PIEs were supplied separately.

```sh
python3 bench/compare_native_os.py --kind os --mode output --pairs 9 \
  --max-rss-mib 4096 --rust "$RUST_CHECKED" --ocaml "$OCAML" \
  --program "$OS_PROGRAM" test/fixtures/os/erc20-transfers-8192.json.gz
python3 bench/compare_native_os_workers.py --kind virtual-os --pairs 9 \
  --rust "$RUST_RELATED" --ocaml "$WORKER" --program "$VIRTUAL_OS_PROGRAM" \
  test/fixtures/os/virtual-multicall-64.json.gz
python3 test/fixtures/os/check.py "$OCAML" "$OS_PROGRAM"
```
