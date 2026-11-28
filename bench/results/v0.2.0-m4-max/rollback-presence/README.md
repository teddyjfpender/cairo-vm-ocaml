# Reverted transaction execution

The OS reads the revert reason to determine whether a transaction reverted. The new projection validates every byte of that JSON value and retains its nullness. This avoids allocating a decoded copy of the error text. Malformed input still follows the strict reader’s error path.

The four-block witness contains 9,216 transactions, including 6,144 reverts, and executes 47.33 million Cairo steps. Each of nine rounds ran the same witness in three fresh processes in seeded random order. The checked Rust sequencer and both OCaml binaries returned identical public output every time. All three received the same compiler program. The program is embedded in the Rust executable. Both OCaml builds used the release PGO training procedure.

| Runner | Median elapsed | Median paired speedup vs Rust |
| --- | ---: | ---: |
| Checked Rust sequencer | 7.822 s | 1.00× |
| Prior OCaml release candidate | 0.811 s | 9.64× |
| OCaml with presence projection | 0.780 s | 10.07× |

The OCaml-only median gain was 1.039× in these nine rounds. Five of the nine individual Rust comparisons reached 10×. In a separate 15-pair trial, all 15 rollback comparisons improved and the median gain was 1.034×. The median for the 8,192-invoke repeated-storage control was 0.999×. The earlier 22-workload qualification used the previous release binary.

All 25 native OS and four Virtual OS fixture checks passed. On a smaller 1,536-transaction rollback fixture the candidate matched the independent Rust trace, 7,630,536 relocated memory cells and public output for all 8,340,910 steps. The focused reader tests cover missing, null, escaped text, nested values and malformed JSON.

The raw three-engine samples are in `rust-and-ocaml.csv`. `ocaml-pgo.csv` records the separate 15 pairs per workload. The compiler and executable digests identify the measured builds. To repeat the Rust comparison, use `bench/compare_native_os.py --kind os --mode output --pairs 9` with the checked runner, the full compiler program and `test/fixtures/os/mixed-reverts-3072.json.gz`.
