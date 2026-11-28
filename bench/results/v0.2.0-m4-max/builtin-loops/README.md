# Checked builtin selection and validation

Across the four original large native OS workloads, the median paired scenario gained 1.049× and the sum of per-case median times gained 1.048×. Each workload has 11 alternating pairs against the preceding OCaml release. [Raw samples](large-paired.csv)

| Native OS workload | Baseline median | Candidate median | Median paired speedup |
| --- | ---: | ---: | ---: |
| 8,192 storage writes | 0.892 s | 0.839 s | 1.068× |
| 8,192 ERC20 transfers | 1.100 s | 1.042 s | 1.052× |
| 9,216 mixed transactions | 0.908 s | 0.869 s | 1.045× |
| 4,096 scattered writes | 0.907 s | 0.884 s | 1.030× |

Fresh-process, same-host Apple M4 Max end-to-end comparisons use ordinary release builds of both revisions. Both CLI invocations read the same program and witness, securely finalize, print all public output, and exit. Each pairing must match public output byte for byte. The four witnesses are randomly ordered each round with Python seed 1212. The first binary alternates with round and witness index. The median scenario speedup uses the median per-case paired speedup. The suite speedup divides the sums of per-case median wall times. Other local projects continued running. See the manifest for exact executable, program and witness hashes.

The storage workload runs 8,192 writes, the transfer case runs 8,192 ERC20 transfers, the mixed workload contains 9,216 transactions including 6,144 reverts, and scattered storage runs 4,096 updates. Native-program instruction counts on the starting binary attributed 32.44% of the storage case and 26.74% of the revert case to the three Cairo builtin-selection/validation functions. The optimized code checks decoded instructions, literal operands and memory constraints. Selection additionally requires the registered canonical hint to be the sole handler at its program counter. Traced runs use the regular interpreter.

The full-memory check uses a distinct CLI run with --layout all_cairo --stats --print_output --memory_file and no trace request. It compares the byte length and SHA-256 of the entire relocated memory file, the charged step count, and SHA-256 of stdout. The 70-witness digest table independently compares fresh and shuffled image-backed CLI public words with saved pinned Rust public-word digests. Focused regression tests compare registers, memory, step counts and watched accesses against scalar execution, including exact native step limits, mixed hints, intermediate stops, and noncanonical hint references.

The final native suite passed 364 selection states, 525 validation states, 50 public-run hint/stop/budget combinations, six long-loop boundary budgets and two real hint-reference binding checks. The 25 upstream OS fixtures matched all PIE member hashes. The generic Rust comparison matched 150 execution and 150 proof cases, 146 successful PIE replays, four replays that failed in both implementations, and two Stwo-exclusive cases. [Native differential results](native-tests.txt) · [Generic parity](generic-parity.txt) · [Sequencer PIE checks](sequencer-pie.txt)
