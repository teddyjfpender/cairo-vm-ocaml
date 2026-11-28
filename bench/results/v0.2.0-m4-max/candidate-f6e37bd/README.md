# Packaged release with PRs 48, 49 and 50

The runtime is `f6e37bd`. The macOS arm64 package contains the CLI, persistent worker, file-based C replay library, headers and licenses. The manifest identifies the measured binaries and the package. The proposed byte-based snapshot provider is documented in the source distribution.

| Workload | Rust | OxCairo | Ratio of summed times | Median per case | Cases at 10× |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold stock sequencer scenarios | 28.24 s | 2.46 s | 11.48× | 3.02× | 19/70 |
| Warm shuffled sequencer scenarios | 5.15 s | 0.93 s | 5.52× | 4.91× | 0/70 |
| Scaled native OS workloads | 157.44 s | 12.82 s | 12.28× | 11.45× | 18/22 |
| Virtual OS and aggregator, public output | 5.14 s | 0.49 s | 10.49× | 7.04× | 2/10 |
| Virtual OS and aggregator, output PIE | 17.55 s | 0.86 s | 20.32× | 19.36× | 9/10 |
| General Cairo execution | 7.49 s | 0.99 s | 7.59× | 7.66× | 5/17 |
| General Cairo trace and memory | 13.34 s | 2.14 s | 6.23× | 6.49× | 0/17 |

Each row sums medians for the individual cases. The median per case gives each workload equal weight and uses within-pair ratios. Comparisons ran on an Apple M4 Max with 36 GiB and other projects active. Native output checks included secure finalization. Both warm workers loaded their compiler before timing and reread the request witness on every run.

In the 350 cold stock comparisons (`timings.csv`) every randomized round used three fresh processes. `before_s` is the preceding packaged OCaml runtime `86fd938`, `both_s` is the merged runtime and `rust_s` is the stock sequencer. Both OCaml runners used the complete compiler JSON whose SHA-256 is `2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded`. Every public word matched the Rust oracle. The previous binary measured 2.99× against Rust at the median under the same conditions.

The 22 scaled native workloads each have five fresh-process comparisons. The CSVs name the stock or memory-bounded checked Rust sequencer for each workload. The two general Cairo CSVs use stock Rust v4 and six runs per program. The `vs-main-*` CSVs compare starting OCaml main with the new OCaml build in eight paired rounds. Their `rust_seconds` column holds the earlier OCaml time because the same CLI comparison harness was used. The separate Virtual OS and aggregator comparisons checked all emitted archives and DA payloads. `direct.csv` covers the two stock Rust v4 production replays and compressed archive generation.

The strict differential suite records positive evidence for execution, traces, memory and output PIEs, with four individually reviewed replay rejections. The smaller Rust 3.2.0 fixture yielded identical trace, memory, public output and five regenerated PIE members on canonical, reordered and identically duplicated records. Both engines rejected conflicting duplicates and a duplicate concealing a missing cell. The four production archives reproduced all saved artifact digests. The final proof exporter also regenerated the exact inputs of all ten independently verified Stwo proofs. See the adjacent text receipts.

The runtime commit passed all four hosted checks on Ubuntu and macOS. [Build and corpus parity](https://github.com/teddyjfpender/cairo-vm-ocaml/actions/runs/46114995111) · [Strict harness regressions and native smoke](https://github.com/teddyjfpender/cairo-vm-ocaml/actions/runs/46114994891)
