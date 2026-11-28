# Native OS release candidate d884acc

All timings here use the PGO executable at `d884acc` on the 36 GiB M4 Max. The binary digests are in `manifest.json`. Independent jobs shared the host. The two engines in each pair ran sequentially and had to produce equal public output.

## Stock sequencer over 70 upstream scenarios

| Execution mode | Paired runs | Rust total | OCaml total | Total ratio | Median paired case ratio | Cases at 10× |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Fresh process, full compiler JSON | 350 | 39.04 s | 4.97 s | 7.85× | 2.18× | 19/70 |
| Fresh process, full compiler JSON, lower host load | 350 | 28.07 s | 2.84 s | 9.89× | 2.68× | 19/70 |
| Fresh process, packed compiler | 210 | 36.27 s | 2.87 s | 12.65× | 3.76× | 19/70 |
| Persistent workers, same input after warmup | 350 | 6.02 s | 1.03 s | 5.83× | 5.30× | 0/70 |
| Persistent workers, shuffled distinct inputs | 350 | 8.97 s | 1.48 s | 6.06× | 5.80× | 3/70 |

Totals sum the median for each engine over each case. For the median ratio, compute Rust time divided by OCaml time within a pair, take the median per case, then take the median across cases. Packing the compiler is a separate one-time operation. The Rust process uses the original compiler in every comparison.

Each worker request starts a new secure VM. The shuffled mode keeps a single process per engine alive during five independently ordered traversals. Each traversal runs every witness once, including the first traversal. The harness stages the witness outside the timer and both engines read and parse it within the timed request. The single-input mode launches new workers for each case, warms them on that case once, then records five pairs.

## Native OS end to end

| Workload | Rust runner | Rust | OCaml | Paired ratio |
| --- | --- | ---: | ---: | ---: |
| storage4096 | stock | 6.980 s | 0.780 s | 9.16× |
| mixed32 | stock | 10.157 s | 0.909 s | 10.84× |
| calldata-1024 | stock | 7.605 s | 0.687 s | 10.76× |
| blob-1024 | stock | 9.697 s | 0.817 s | 11.86× |
| sequential-2048 | stock | 4.227 s | 0.390 s | 11.65× |
| scattered-2048 | stock | 10.066 s | 0.514 s | 18.49× |
| storage8192 | verified | 7.592 s | 0.867 s | 8.87× |
| mixed64 | verified | 9.046 s | 0.890 s | 10.18× |
| sequential-4096 | verified | 5.474 s | 0.545 s | 10.07× |
| scattered-4096 | verified | 14.270 s | 0.854 s | 16.79× |
| calldata-2048 | verified | 11.412 s | 1.082 s | 10.52× |
| blob-2048 | verified | 12.800 s | 1.129 s | 11.27× |
| 256 STRK transfers, 16 recipients | stock | 1.579 s | 0.072 s | 21.98× |
| 1024 STRK transfers, 16 recipients | stock | 2.523 s | 0.164 s | 15.32× |
| 2048 STRK transfers, 2048 recipients | stock | 8.992 s | 0.479 s | 18.71× |
| 4096 STRK transfers, 16 recipients | verified | 5.820 s | 0.506 s | 11.48× |
| 4096 STRK transfers, 4096 recipients | verified | 17.299 s | 0.949 s | 18.19× |

The stock Rust rows use the upstream sequencer entry point. The checked runner executes the same hint processor, return checks and auto-deductions and omits unrequested relocated output objects. These contract workloads use sequencer-generated witnesses. The historical production data below consists of previously executed PIEs.

## Production replay and general VM

| Secure Rust v4 replay | Rust | OCaml | Paired ratio |
| --- | ---: | ---: | ---: |
| SN_PIE_2, exec | 3.413 s | 0.216 s | 15.63× |
| SN_PIE_3, exec | 6.388 s | 0.410 s | 15.57× |
| SN_PIE_2, compressed | 7.843 s | 0.687 s | 11.41× |

All four historical production archives reproduced the checkpoint’s complete trace, relocated memory, output and five decompressed archive members. The two archives that fit the comparison budget were also timed against Rust v4.

| 17-program suite | Total vs Rust v4 | Mean per-program ratio | Median paired case ratio |
| --- | ---: | ---: | ---: |
| execution | 8.05× | 8.84× | 8.95× |
| traced | 6.24× | 6.20× | 6.22× |

Full native trace and memory receipts cover seven OS, Virtual OS and aggregator workloads. All 42 engine executions agreed byte for byte with their paired engine. `prover-inputs.txt` records the ten exact upstream-verified Stwo inputs. The release fixture and generic parity logs record the remaining acceptance results.

Use `bench/compare_native_os.py` for cold comparisons and `bench/compare_native_os_workers.py --shuffle-seed 6640` to reproduce the mixed-worker mode. The parent directory describes the native diagnostic, corpus and upstream revisions.
