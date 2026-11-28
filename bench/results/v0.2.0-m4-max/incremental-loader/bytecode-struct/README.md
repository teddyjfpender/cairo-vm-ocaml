# Bytecode and struct projection

The regular-release binary from `24a0060` achieved a **1.056× median wall speedup and 1.044× median child CPU speedup** over `a28367a` on 70 upstream scenarios. Each of 630 pairs ran two fresh processes on the identical 52,471,230-byte raw compiler input. Each pair returned byte-identical stdout and matched the retained Rust output digest. Of 70 case medians, 65 improved. Individual medians ranged from 0.995× to 1.117×. The one-minute load ranged from 10.22 to 10.69 on the 14-core M4 Max. This series measures an incremental loader change with ordinary release compilation.

| Focused input | Pairs | Base median ms | Candidate median ms | Median of paired wall ratios |
|---|---:|---:|---:|---:|
| Genesis | 25 | 21.42 | 19.39 | 1.108× |
| Cairo0 | 25 | 33.44 | 32.74 | 1.025× |
| Cairo1 | 25 | 32.99 | 31.31 | 1.070× |
| Transfer1024 | 25 | 165.75 | 161.34 | 1.022× |
| Storage8192 | 13 | 883.21 | 879.61 | 1.012× |

The candidate reads ordinary bytecode strings as validation-bounded source spans. A bounded per-document direct-mapped table compares their lengths and bytes before reusing a previously parsed integer. The struct path projects the compiler’s ordinary key ordering directly into the VM’s two member lists. Other shapes fall back to the existing reader. The paths preserve the first root data field and the original order of members and identifier insertions. No file-derived state persists between runs.

The full raw compiler packed to byte-identical program images. Both versions had identical exit codes, stderr, stdout and packed bytes on 267 targeted documents and 608 deterministic complete and malformed inputs (145 accepted, 463 rejected). All 25 upstream fixture PIE members and public output matched. The release test suite passed, including regressions for duplicate roots and member keys, Unicode escapes and the native block and struct-capacity boundaries.

## Reproduction

Build each revision with the same OCaml and native compiler using `dune build --profile release -j1 bin/main.exe`. Run the previously retained harness as `python3 ../typed-compiler/compare.py BASE CANDIDATE RAW_PROGRAM WITNESS_DIRECTORY OUTPUT_CSV` from this directory. It validates raw input and witness hashes, alternates execution order and checks the normalized Rust output after each pair. The measured executables had SHA-256 hashes `9950c073d2dc30f6a5d2483b7200a9324bac308cb05fb6dc6f44bf49313f3d95` (base) and `b1e8d503b41188bc8920845e42ad5f29ba3095621063ecb3a704507f1e6d60b2` (candidate).

## Additional experiments

The 15-process phase profile used the baseline with timing probes. The two middle cases spent 5.70 / 5.98 ms reading the compiler input and 5.62 / 5.60 ms constructing the program document. The parallel strict debug validator took 4.43 ms in both workloads and returned before document construction finished. Program conversion took 3.60 / 2.33 ms and runner initialization took 1.17 / 1.25 ms. The phases overlap.

Three earlier private experiments used these same five focused inputs. Bytecode projection alone reached a 1.011× median of workload wall speedups. Splitting positional reads into independently parsed program edges and a debug span gave 0.825×, with a 0.816× genesis regression. Bulk loading a fresh segment with deduplicated field conversion and instruction predecoding gave 0.994×. The three CSV files preserve the per-run results for those experiments.
