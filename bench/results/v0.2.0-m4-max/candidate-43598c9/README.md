# Native OS release candidate 43598c9

All timings here use the PGO executable at `43598c9` on the 36 GiB M4 Max. The binary digests are in `manifest.json`. Independent jobs shared the host. The two engines in each pair ran sequentially and had to produce equal public output.

## Stock sequencer over 70 upstream scenarios

| Execution mode | Paired runs | Rust total | OCaml total | Total ratio | Median paired case ratio | Cases at 10× |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Fresh process, full compiler JSON | 350 | 29.15 s | 3.55 s | 8.21× | 2.31× | 19/70 |
| Fresh process, packed compiler | 210 | 28.16 s | 1.85 s | 15.22× | 4.19× | 19/70 |
| Persistent workers, same input after warmup | 350 | 5.17 s | 0.86 s | 6.05× | 5.12× | 0/70 |
| Persistent workers, shuffled distinct inputs | 350 | 6.11 s | 1.12 s | 5.45× | 5.31× | 0/70 |

Totals sum the median for each engine over each case. For the median ratio, compute Rust time divided by OCaml time within a pair, take the median per case, then take the median across cases. Packing the compiler is a separate one-time operation. The Rust process uses the original compiler in every comparison.

Each worker request starts a new secure VM. The shuffled mode keeps a single process per engine alive during five independently ordered traversals. Each traversal runs every witness once, including the first traversal. The harness stages the witness outside the timer and both engines read and parse it within the timed request. The single-input mode launches new workers for each case, warms them on that case once, then records five pairs.

## Native OS end to end

| Workload | Rust runner | Rust | OCaml | Paired ratio |
| --- | --- | ---: | ---: | ---: |
| storage4096 | stock | 4.747 s | 0.517 s | 9.49× |
| mixed32 | stock | 6.035 s | 0.548 s | 10.90× |
| calldata-1024 | stock | 6.026 s | 0.565 s | 10.53× |
| blob-1024 | stock | 7.327 s | 0.612 s | 11.98× |
| sequential-2048 | stock | 3.547 s | 0.299 s | 11.89× |
| scattered-2048 | stock | 7.608 s | 0.462 s | 16.48× |
| storage8192 | verified | 7.427 s | 0.837 s | 8.80× |
| mixed64 | verified | 9.218 s | 0.940 s | 9.81× |
| sequential-4096 | verified | 5.688 s | 0.585 s | 9.72× |
| scattered-4096 | verified | 14.188 s | 0.862 s | 16.55× |
| calldata-2048 | verified | 11.601 s | 1.122 s | 10.40× |
| blob-2048 | verified | 13.250 s | 1.228 s | 10.78× |
| 256 STRK transfers, 16 recipients | stock | 1.594 s | 0.076 s | 21.05× |
| 1024 STRK transfers, 16 recipients | stock | 2.532 s | 0.173 s | 14.75× |
| 2048 STRK transfers, 2048 recipients | stock | 9.196 s | 0.505 s | 18.18× |
| 4096 STRK transfers, 16 recipients | verified | 5.843 s | 0.515 s | 11.37× |
| 4096 STRK transfers, 4096 recipients | verified | 18.296 s | 1.013 s | 18.03× |
| 8192 STRK transfers, 16 recipients | verified | 16.584 s | 1.764 s | 10.25× |
| 384 transactions, 256 reverted | stock | 1.775 s | 0.136 s | 13.03× |
| 1536 transactions, 1024 reverted | stock | 3.081 s | 0.272 s | 11.82× |
| 4608 transactions, 3072 reverted | verified | 6.232 s | 0.570 s | 9.89× |
| 9216 transactions, 6144 reverted | verified | 10.200 s | 1.046 s | 9.76× |

The stock Rust rows use the upstream sequencer entry point. The checked runner executes the same hint processor, return checks and auto-deductions and omits unrequested relocated output objects. These contract workloads use sequencer-generated witnesses. The historical production data below consists of previously executed PIEs.

## Production replay and general VM

| Secure Rust v4 replay | Rust | OCaml | Paired ratio |
| --- | ---: | ---: | ---: |
| SN_PIE_2, exec | 3.515 s | 0.223 s | 15.83× |
| SN_PIE_3, exec | 6.815 s | 0.449 s | 15.46× |
| SN_PIE_2, compressed | 8.206 s | 0.807 s | 10.17× |

All four historical production archives reproduced the checkpoint’s complete trace, relocated memory, output and five decompressed archive members. The two archives that fit the comparison budget were also timed against Rust v4.

| 17-program suite | Total vs Rust v4 | Mean per-program ratio | Median paired case ratio |
| --- | ---: | ---: | ---: |
| execution | 7.66× | 8.42× | 7.84× |
| traced | 6.27× | 6.35× | 6.65× |

Full native trace and memory receipts cover seven OS, Virtual OS and aggregator workloads. All 42 engine executions agreed byte for byte with their paired engine. `prover-inputs.txt` records the ten exact upstream-verified Stwo inputs. The release fixture and generic parity logs record the remaining acceptance results.

Use `bench/compare_native_os.py` for cold comparisons and `bench/compare_native_os_workers.py --shuffle-seed 6640` to reproduce the mixed-worker mode. The parent directory describes the native diagnostic, corpus and upstream revisions.
