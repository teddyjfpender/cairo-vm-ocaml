# Packaged release candidate 86fd938

The five-round cold comparison uses 70 stock sequencer scenarios, seeded shuffles of both scenarios and engine order, and a fresh process for each invocation. Rust executes its embedded compiler and the two OCaml runners read that exact 52,471,230-byte JSON file. Each execution securely finalizes and prints the public words. Every row matched the independent Rust output digest. All measurements used the same Apple M4 Max with 36 GiB of memory.

| Engine | Summed case medians | Median per-scenario speedup vs Rust | Summed-time speedup vs Rust |
| --- | ---: | ---: | ---: |
| Stock Rust sequencer | 27.646 s | 1.00× | 1.00× |
| Previous OCaml runtime 71d5e92 | 2.313 s | 3.04× | 11.95× |
| Packaged OCaml runtime 86fd938 | 2.234 s | **3.18×** | **12.38×** |

Both OCaml runtimes reached 10× on 19 of 70 cases. Relative to the preceding OCaml runtime, 63 scenario medians improved and the median paired speedup was 1.039×. The two middle cases had Rust medians of 97.5 and 97.6 ms and OCaml medians of 31.1 and 30.9 ms. Each would need roughly 9.8 ms to reach 10×.

A separate five-round shuffle used warm Rust and OCaml workers. The 350 requests matched and their scenario ratios had a 4.81× median. The case medians summed to 5.09 s Rust and 0.94 s OCaml (5.43×). No warm case median reached 10×. Both workers create a fresh VM and reread the witness for every request.

## Reproduction and correctness

The cold samples are in `timings.csv`, with `before_s` for the previous PGO binary and `both_s` for the packaged PGO binary. The shuffled worker samples are in `shuffled.csv`. The separate four-case OCaml comparison is in `before-cairo-vm-cli-large.csv`. All nine pairs per large workload compared byte-identical public output.

Build the PGO runner and worker with `scripts/build_pgo.py`. The native benchmarks use `bench/compare_native_os.py` and `bench/compare_native_os_workers.py`. The earlier change-specific experiments give their own source revisions and timings.

The 25 OS fixtures, four Virtual OS fixtures and 13 aggregator configurations passed, alongside the randomized encryption checks. All four production PIEs reproduced the full reference trace, relocated memory and five output archive members. The generic differential suite matched 150 execution and 150 proof cases, 146 successful replays and four shared failures, and both Stwo extension programs. A freshly built proof-mode exporter regenerated the identical input for each of ten verified Stwo proofs. The packaged CLI, worker and C interface also passed their standalone checks. See `pies.txt`, `proofs.txt`, `parity.txt` and `package.txt`.
