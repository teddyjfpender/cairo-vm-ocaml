# OxCairo 0.2.0 release qualification

The release candidate runs the pinned Starknet OS, Virtual OS and aggregator from native witnesses. Secure replay and several large contract workloads exceed 10× Rust. Short native scenarios, repeated storage and some artifact-emitting workloads remain below the release target.

## Performance after builtin loop and compiler changes

Runtime `86fd938` was measured before including the three release-quality PRs. Timings use fresh processes unless marked warm. Rust comparisons use the stock VM v4 CLI for generic programs and production replay, and the pinned sequencer for native witnesses. The 22 scaled cases include stock and memory-bounded checked sequencer runs, identified in the raw data.

| Workload | Median scenario vs Rust | Ratio of summed case times | At least 10× |
| --- | ---: | ---: | ---: |
| Stock OS, 70 cold scenarios | 3.18× | 12.38× | 19/70 |
| Stock OS, 70 warm shuffled scenarios | 4.81× | 5.43× | 0/70 |
| Scaled storage, syscalls, deployments, transfers and reverts | 11.39× | 12.31× | 18/22 |
| Virtual OS and aggregator, public output | 7.15× | 10.36× | 2/10 |
| Virtual OS and aggregator, output PIE | 20.56× | 22.21× | 9/10 |
| General Cairo programs, execution | 7.51× | 7.60× | 5/17 |
| General Cairo programs, trace and memory files | 5.74× | 5.16× | 0/17 |

On the four scaled cases below the target, repeated storage at 4,096 and 8,192 invokes reached 9.75× and 9.16×, the larger mixed-syscall case reached 9.93×, and the 4,096 sequential-update case reached 9.90×. The 9,216-transaction mixed rollback case reached 10.14×. Secure replay reached 15.60× on SN_PIE_2 and 15.56× on SN_PIE_3. Emitting a compressed SN_PIE_2 archive reached 10.78×.

Against the starting OCaml main on this machine, the 17-program suite took 0.949 s versus 0.942 s for execution and 2.445 s versus 2.588 s with trace and memory files. This corresponds to 1.008× execution and 0.945× traced performance. All output comparisons passed. Other projects were running on the host; case medians and summed-time ratios use the raw matched samples. [Pairs, binary digests and parity evidence](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/release/os-performance/bench/results/v0.2.0-m4-max/candidate-86fd938)

## Full compiler loader refinement

At runtime `16aa093`, the median cold speedup across 70 stock sequencer scenarios was **3.25×**, and **19/70** reached 10×. The Rust case medians summed to 28.16 s, against 2.32 s for OxCairo, or **12.15×**. Each of five rounds shuffled the scenarios and the order of four engines per scenario. Every process returned the same public words. All three OCaml builds used release PGO and read the full compiler JSON.

| Engine | Median scenario speedup vs stock Rust | Sum of case medians |
| --- | ---: | ---: |
| Stock sequencer | 1.00× | 28.16 s |
| Previous OCaml runtime, `7e611bc` | 2.82× | 2.66 s |
| Batched identifiers and references, `afbf090` | 2.90× | 2.61 s |
| Batched records and parallel debug validation, `16aa093` | **3.25×** | **2.32 s** |

The two middle scenarios both run a Cairo 1 contract with full OS output. Their Rust case medians were 105.8 and 105.7 ms, against 32.6 and 32.1 ms in OxCairo. Hitting 10× at those Rust times would require about 10.6 ms per invocation.

In the matched comparison, all 70 scenarios improved against the previous OCaml runtime. The median incremental speedup was **1.142×** and the summed runtime improved **1.150×**. The new build matched the saved native, Virtual OS and aggregator archives, randomized encryption checks and the generic Rust differential suite. The packaged worker, CLI and C library passed their smoke tests and produced matching trace, memory and archive contents. [Full four-engine timings and binary identities](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/release/os-performance/bench/results/v0.2.0-m4-max/incremental-loader/typed-compiler)

## Previous release candidate against Rust

| 70 upstream scenarios | Rust suite time | OxCairo suite time | Total ratio | Median scenario | At least 10× |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold, full compiler, heavier concurrent load | 39.04 s | 4.97 s | 7.85× | **2.18×** | 19/70 |
| Cold, full compiler, lighter concurrent load | 28.07 s | 2.84 s | 9.89× | **2.68×** | 19/70 |
| Cold, packed compiler, heavier concurrent load | 36.27 s | 2.87 s | 12.65× | **3.76×** | 19/70 |
| Cold, packed compiler, lighter concurrent load | 28.22 s | 1.76 s | 16.07× | **4.48×** | 19/70 |
| Warm, same witness after warmup | 6.02 s | 1.03 s | 5.83× | **5.30×** | 0/70 |
| Warm, five shuffled traversals | 8.97 s | 1.48 s | 6.06× | **5.80×** | 3/70 |

Each workload gets one vote in the median. The suite-time ratio weights workloads by their elapsed time. Packing the 52,471,230-byte compiler once took 65 ms. In the lighter cold run, the two middle scenarios were the new-account flow and the proof-facts/version check. Their Rust medians were 93.1 and 98.5 ms, against OCaml medians of 36.2 and 36.8 ms. A 10× result on those cases would require about 9–10 ms end to end. Both warm measurements keep the Rust and OCaml workers alive. Each request reads a witness from disk and creates a fresh secure VM.

| End-to-end workload | Rust runner | Rust | OxCairo | Paired ratio |
| --- | --- | ---: | ---: | ---: |
| SN_PIE_2, execution | stock v4 | 3.413 s | 0.216 s | **15.63×** |
| SN_PIE_3, execution | stock v4 | 6.388 s | 0.410 s | **15.57×** |
| SN_PIE_2, compressed archive | stock v4 | 7.843 s | 0.687 s | **11.41×** |
| 4,096 repeated storage invokes | stock sequencer | 6.980 s | 0.780 s | **9.16×** |
| 8,192 repeated storage invokes | checked sequencer | 7.592 s | 0.867 s | **8.87×** |
| 4,096 scattered writes | checked sequencer | 14.270 s | 0.854 s | **16.79×** |
| Five blocks of mixed syscalls, 64 rounds | checked sequencer | 9.046 s | 0.890 s | **10.18×** |
| 8,192 STRK transfers, 16 recipients | checked sequencer | 10.465 s | 1.000 s | **10.40×** |
| 4,096 STRK transfers, 4,096 recipients | checked sequencer | 17.299 s | 0.949 s | **18.19×** |
| 9,216 transactions, including 6,144 reverts | checked sequencer | 7.902 s | 0.833 s | **9.47×** |
| Virtual OS, 312 nested calls, public output | stock sequencer | 0.508 s | 0.085 s | **6.01×** |
| Virtual OS, same witness, full PIE | stock sequencer | 3.078 s | 0.145 s | **21.30×** |
| Aggregator, 2,048 blocks, public output | stock sequencer | 0.354 s | 0.036 s | **9.92×** |
| Aggregator, same witness, full PIE | stock sequencer | 1.368 s | 0.069 s | **19.64×** |

Across the 22 storage, syscall, deploy, transfer and revert workloads in the full cold comparison, **19 of 22** reached 10×. The median workload speedup was **11.38×**. The three below 10× were the 4,096- and 8,192-invoke repeated-storage cases and the 9,216-transaction reversion case.

The checked sequencer executes native hints and validates the VM through return-value and builtin checks. It omits the unrequested relocated image and archive. The larger contract workloads use witnesses generated by the upstream sequencer and Blockifier. The production PIEs are historical archives.

The 17-program generic suite ran **8.05×** faster than stock Rust v4 in aggregate for execution and **6.24×** with trace and memory emission on this host. The matched same-machine comparison with starting OCaml `main` measured **1.06×** and **1.04×**, respectively.

Compared directly with the earlier traced-kernel checkpoint `e559436`, the final PGO build improved median cold time by **1.11×** and median shuffled worker time by **1.24×**. Under lighter load, the last loader revision alone improved median cold time **1.10×** relative to `43598c9` over 490 pairs. The earlier busy comparison measured **1.004×** over 350 pairs.

The packaged worker completed 4,049 fresh VMs across 74 shuffled witnesses at a peak sampled RSS of 641 MiB. All outputs matched stock Rust. Both Linux and macOS CI passed on the runtime revision. The four historical production archives reproduced complete traces, relocated memory, output and archive contents. All seven native trace/memory cases matched Rust in every pair. Ten complete Stwo prover inputs reproduced the independently verified Rust digests, and all ten proof files passed the upstream verifier.

[Release candidate measurements and reproduction commands](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/e9f95e47910eebab1591b8a4ac38efd97fd86768/bench/results/v0.2.0-m4-max/candidate-d884acc) · [Hosted checks for this runtime](https://github.com/teddyjfpender/cairo-vm-ocaml/actions/runs/46110168349) · [Run the packaged OS worker](getting-started.md#run-successive-blocks-in-one-process)

## Earlier checkpoint

The measurements below were taken at runtime checkpoint `e559436` on the M4 Max.

### Native Starknet OS

Each cold run starts a process, reads a witness, executes the Cairo program and returns the public output. The compiler image is the full 52,471,230-byte file embedded by Rust. The stock Rust sequencer builds its normal output objects. The checked Rust diagnostic uses the same sequencer hints, VM end checks, auto-deduction verification and return-value checks and omits the unused relocated image and PIE. Its separate streaming writer provided independent archive-member hashes.

| Native workload | Rust reference | Rust median | OxCairo median | Paired ratio |
| --- | --- | ---: | ---: | ---: |
| 4,096 repeated storage invokes | stock | 4.235 s | 0.467 s | **9.03×** |
| Five blocks of mixed syscalls, 32 rounds | stock | 5.582 s | 0.497 s | **11.13×** |
| 3,073 deploy, write and L1 transactions, calldata | stock | 6.293 s | 0.603 s | **10.63×** |
| 3,073 deploy, write and L1 transactions, blob | stock | 7.154 s | 0.606 s | **11.80×** |
| 2,048 distinct sequential writes | stock | 3.580 s | 0.319 s | **11.23×** |
| 2,048 distinct scattered writes | stock | 7.583 s | 0.467 s | **16.18×** |
| 8,192 repeated storage invokes, 51.84M steps | checked | 7.405 s | 0.838 s | **8.77×** |
| Five blocks of mixed syscalls, 42.22M steps | checked | 9.127 s | 0.913 s | **10.01×** |
| 4,096 distinct sequential writes, 29.75M steps | checked | 5.524 s | 0.574 s | **9.61×** |
| 4,096 distinct scattered writes, 34.56M steps | checked | 14.225 s | 0.879 s | **16.38×** |
| 6,145 deploy, write and L1 transactions, calldata | checked | 11.735 s | 1.124 s | **10.43×** |
| 6,145 deploy, write and L1 transactions, blob | checked | 12.927 s | 1.171 s | **11.02×** |
| 1,024 STRK transfers, 16 recipients | stock | 2.457 s | 0.157 s | **15.70×** |
| 2,048 STRK transfers, 2,048 recipients | stock | 8.941 s | 0.490 s | **18.22×** |
| 4,096 STRK transfers, 4,096 recipients | checked | 17.566 s | 0.950 s | **18.37×** |
| 8,192 STRK transfers, 16 recipients | checked | 10.351 s | 0.977 s | **10.60×** |
| 9,216 transactions including 6,144 reverts, 47.33M steps | checked | 7.868 s | 0.810 s | **9.63×** |

The transfer witnesses execute the STRK ERC20 contract across four blocks. The largest transfer run executes 64,202,029 Cairo steps. The recipient-fanout run executes 42,013,031 steps. The reversion witness combines Cairo 0 and Cairo 1 execution with successful state writes. These large witnesses were generated by the pinned sequencer and Blockifier.

### Short cases and cold startup

On the 70 deterministic upstream scenarios, the **median per-case speedup is 2.09× cold and 3.46× warm**. The cold times summed across cases are 28.59 s Rust and 3.72 s OxCairo, a **7.68×** total ratio. Each process reads the complete compiler image for the cold runs. Each worker warms up on one request and creates a fresh VM for every subsequent request. The two engines use the stock sequencer API and the prepared OCaml program in their respective workers.

The middle cases and their measured cold times are shown below.

| Upstream case | Rust | OxCairo | Paired ratio |
| --- | ---: | ---: | ---: |
| `test_new_class_execution_info-use_kzg_da_2_false` | 0.097 s | 0.047 s | **2.08×** |
| `trivial_diff_scenario-use_kzg_da_1_false-full_output_1_false-test_contract_2_FeatureContract__TestContract_CairoVersion__Cairo1_RunnableCairo` | 0.102 s | 0.048 s | **2.10×** |

### Large OS archives and related programs

| Secure direct replay, stock Rust v4 | Rust | OxCairo | Paired ratio |
| --- | ---: | ---: | ---: |
| SN_PIE_2 public output | 3.337 s | 0.224 s | **14.48×** |
| SN_PIE_3 public output | 6.268 s | 0.423 s | **14.83×** |
| SN_PIE_2 with DEFLATE output from both engines | 7.900 s | 0.711 s | **11.12×** |

Across all four production archives, secure replay improved **2.89–3.10× over the earlier OCaml PIE branch**. Release qualification reproduced the output, binary trace, relocated memory and decompressed PIE members on all four against that previously Rust-qualified branch. SN_PIE_2 also matched a fresh stock Rust v4 full-artifact run. The two largest historical stock Rust runs exceeded the later memory budget. Those historical comparisons are retained in the benchmark history.

| Related cold workload, stock sequencer | Public output | With PIE output |
| --- | ---: | ---: |
| Virtual OS, 104 multicalls and 312 nested syscalls | 5.88× | 20.01× |
| Aggregator, 2,048 blocks | 9.65× | 19.37× |
| Aggregator, 4,096 sequential updates with blob DA | 19.00× | 27.20× |
| Aggregator, 4,096 scattered updates with blob DA | 12.75× | 24.09× |
| Aggregator, 4,096 sequential updates with calldata | 8.14× | 18.95× |
| Aggregator, 4,096 scattered updates with calldata | 7.54× | 19.33× |

### Trace and relocated memory

Both native runners used secure execution and emitted complete trace and memory files. The Rust diagnostic calls the standard Cairo VM binary encoders. Every byte matched for every pair, including each public word.

| Native workload | Cairo steps | Rust | OxCairo | Paired ratio |
| --- | ---: | ---: | ---: | ---: |
| genesis | 7,007 | 0.048 s | 0.042 s | **1.17×** |
| transfer-256 | 2,245,677 | 1.730 s | 0.104 s | **16.82×** |
| transfer-1024 | 8,241,453 | 3.009 s | 0.280 s | **10.72×** |
| storage-2048 | 13,101,755 | 2.923 s | 0.409 s | **7.16×** |
| rollback-1536 | 8,340,910 | 3.019 s | 0.301 s | **10.03×** |
| multicall-104 | 2,694,048 | 0.630 s | 0.120 s | **5.24×** |
| chain-2048 | 1,882,608 | 0.342 s | 0.055 s | **6.21×** |

The simple bootloader runs each production PIE in proof mode. The raw tables include 48 pairs across four archives, with and without padding and with and without trace and memory files. Every pair checks the fact topology and public output. Artifact pairs check binary trace and memory as well.

### Generic suite and earlier OCaml release

| 17-program suite | Total ratio vs Rust v4 | Mean of per-program ratios | Total ratio vs starting OCaml main |
| --- | ---: | ---: | ---: |
| execution | 7.60× | 8.31× | 1.01× |
| traced | 5.93× | 6.05× | 1.00× |

The earlier M5 Max benchmark used best-of-three measurements on different hardware. The figures above come from this M4 Max and use medians.

### Correctness and proving

The release binary matched the pinned sequencer on 25 native OS witnesses, four Virtual OS witnesses and 13 aggregator configurations. Seventy deterministic upstream flow scenarios matched the five PIE-member digests and public output. The four randomized encryption configurations were checked twice with the independent sequencer decryptor and checked against public output and KZG commitments.

The generic Rust v4 corpus passed 150 execution and PIE-output cases, 150 proof-mode cases and two Stwo opcode cases. Replay passed 146 cases and both engines rejected the other four. Ten upstream Stwo proofs verified, including two direct proof-mode `os.cairo` runs and four sequencer-produced tasks inside the simple bootloader. The complete adapted inputs matched Rust. Direct full-layout raw state also matched Rust for genesis, multiblock, account and reverted invoke. The pinned adapter does not support the ECDSA builtin in that layout. The resource-limited proof settings and exact proof hashes are recorded with the verifier receipts.

### Interpreting these measurements

All timed pairs use sequential engine executions on an Apple M4 Max with 36 GiB. Other work was running on the host. The table times are separate engine medians, while speedups use paired ratios. The total-suite figures sum each engine’s case medians before division. The raw data identifies both Rust API variants, modes, compiler images, binary digests and the comparison with starting `main`.

[Raw measurements and reproduction commands](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/0e7f82e683539d15039a562fb3b12204090e0245/bench/results/v0.2.0-m4-max) · [Parity](parity.md) · [Benchmark history](benchmarks.md)
