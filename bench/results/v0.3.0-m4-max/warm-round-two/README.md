# Warm VM execution and PIE publication

The benchmark starts at submission of an already prepared witness to a resident worker and ends at its reply. The reference and candidates execute a fresh VM on every request. All use the 17,259-word OS from Apollo revision `1860b9850b5c51858c50c0f5038933e49f932eef`. The two mainnet captures contain two and three transactions. The other witnesses are generated transfers at the specified scale, including one job with four blocks of 250 transactions.

The in-process comparison ends after both engines close the archive. The production OxCairo worker also forks a bounded child, computes a SHA-256 receipt, synchronizes the file, and publishes it atomically. The Rust reference finishes at close in both comparisons. Each table uses three paired second requests per case on a shared macOS Apple M4 Max. Times are median milliseconds. Each speedup is the median of per-pair ratios. Variation between the Rust columns comes from separate interleaved runs. The raw observations include startup and all four requests in each rotation.

The starting OxCairo tree is `299d4db` (resident worker, binary witness reader and native driver). The in-process after build uses `3653c63`, adding the execution, resource accounting and PIE writer changes. The guarded after build uses `36dee18`, adding exact stored-header publication with concurrent SHA-256. Both use the same OxCaml release configuration, native CPU tuning, OpenSSL, libdeflate and pinned ZIP library. The ordinary stored and pinned Rust profiles are timed separately. All timed jobs publish a complete archive. Content verification occurs after the reply. Witness assembly, class compilation, RPC, proving, and node block production are outside these measurements.

## Stored PIE, in process

| Workload | Rust (ms) | OxCairo before (ms) | OxCairo after (ms) | Before / after | Rust / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mainnet 16,000,001 | 137.5 | 49 | 43.5 | 1.14× | 3.16× |
| Mainnet 16,149,540 | 339.3 | 115.1 | 113.9 | 1.01× | 3.01× |
| 100 transfers | 209.1 | 48.5 | 40.6 | 1.17× | 5.1× |
| 500 transfers | 687.6 | 167.9 | 129.7 | 1.29× | 5.13× |
| 1,000 transfers | 1305.1 | 297.2 | 267 | 1.11× | 4.66× |
| 4 × 250 transfers | 1411.3 | 319.1 | 280.6 | 1.14× | 5.03× |

## Stored PIE, guarded worker

| Workload | Rust (ms) | OxCairo before (ms) | OxCairo after (ms) | Before / after | Rust / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mainnet 16,000,001 | 134 | 68.4 | 66.2 | 1.03× | 2.03× |
| Mainnet 16,149,540 | 352.2 | 164.1 | 153.7 | 1.07× | 2.17× |
| 100 transfers | 194.8 | 63.6 | 53.6 | 1.19× | 3.66× |
| 500 transfers | 649.3 | 212.2 | 164.4 | 1.28× | 3.94× |
| 1,000 transfers | 1214.5 | 389.6 | 319.9 | 1.26× | 3.89× |
| 4 × 250 transfers | 1416.4 | 419.6 | 340.6 | 1.23× | 4.1× |

## Pinned Rust-compatible DEFLATE, in process

| Workload | Rust (ms) | OxCairo before (ms) | OxCairo after (ms) | Before / after | Rust / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mainnet 16,000,001 | 527.7 | 422.4 | 416.4 | 1.01× | 1.26× |
| Mainnet 16,149,540 | 1370.3 | 1106.5 | 1108.2 | 1× | 1.23× |

## Where the remaining time goes

| Workload | Witness read and init (ms) | VM, hints and builtins (ms) | Finalization (ms) | PIE construction and write (ms) |
| --- | ---: | ---: | ---: | ---: |
| 100-1 | 5.2 | 20.4 | 2 | 12.9 |
| 1000-1 | 10.7 | 127.5 | 5.1 | 122.8 |
| 1000-4 | 11.6 | 137.8 | 11 | 120.1 |
| 16000001 | 8.5 | 18.1 | 5.2 | 11.6 |
| 16149540 | 19.3 | 46.2 | 7.4 | 40.2 |
| 500-1 | 8.9 | 67.3 | 3.4 | 46.1 |

These independently measured phase medians need not sum to the median request time. On 1,000 transfers the stored archive is 290,228,641 bytes. The four-block archive is 304,111,485 bytes. Both VM execution and complete artifact publication consume a substantial fraction of the host interval.

The four canonical JSON members and exact memory bytes matched the independent Rust oracle on every request. All OxCairo comparisons in each profile produced the same archive digest before and after. Guarded SHA-256 and byte-count receipts were independently recomputed from disk. The native fused-row tests also checked registers, trace rows, memory and partial execution against the scalar interpreter. Three samples per table cell give directional comparisons on this shared machine. Use the per-request files for dispersion and workload-switch observations.

The scaling fixture exporter is available in [the warm attribution harness](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/89). The [paired driver](../../../warm-host/README.md) verifies every generated artifact. Raw rows are in [stored in-process](core.jsonl), [stored guarded](guard.jsonl), and [pinned compression](standard.jsonl). The same case names identify the per-phase results and the raw files.

Isolating execution, one thousand generated transfers fell from 138.5 to 126.6 ms in a single block and from 147.7 to 134.7 ms across four blocks. The small captured cases changed by less than 0.2 ms. A separate replay of the one-block trace reduced finalized PIE access counting from about 39 ms to 11 ms. In the optional fast-1 compression profile, isolated publication fell from 249.3 to 180.8 ms on one thousand transfers and from 37.4 to 26.1 ms on one hundred. These isolated before/after experiments overlap the timed stages above. [Execution measurements](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/94) · [Access accounting](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/95) · [Fast compression](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/96) · [Concurrent guarded SHA-256](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/97)

[Executable and prepared witness SHA-256 identities](identities.txt)

On the one-block 1,000-transfer fixture, 10× would require about 131 ms for the in-process request and about 121 ms for the guarded request, using the Rust median in each run. The in-process VM stage alone measured 128 ms. Its PIE stage measured 123 ms. The candidate's three individual in-process observations were 735, 267 and 246 ms, so the results do not establish tail latency. No measured workload reached a median 10× advantage. The two real-block pinned-DEFLATE comparisons produced identical full ZIPs across all three arms.

## Encoding the prepared input at the caller

This second, two-job driver starts from the same already materialized witness values. It charges each arm for encoding the input, writing it and receiving the worker reply. Rust uses its JSON producer and the OxCairo guarded workers use the binary OXW1 producer. Both jobs publish checked stored PIEs. Matching or switching the second input distinguishes repeat measurements from a worker receiving another block. Each row contains three paired observations. Building the source witness in the node precedes this timer.

| Previous block | Timed block | Rust JSON (ms) | OxCairo binary before (ms) | OxCairo binary after (ms) | Paired Rust / after |
| --- | --- | ---: | ---: | ---: | ---: |
| 16000001 | 16000001 | 153.1 | 83.6 | 75.9 | 2.03× |
| 16000001 | 16149540 | 359.6 | 177.9 | 189.9 | 1.87× |
| 16149540 | 16000001 | 153.6 | 105.4 | 73.6 | 2.08× |
| 16149540 | 16149540 | 399.1 | 191.8 | 194.7 | 2.09× |

[Materialized-input samples](materialized.jsonl)
