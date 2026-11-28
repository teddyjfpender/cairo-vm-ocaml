# Warm prepared JSON to a complete Starknet OS PIE

Two captured mainnet witnesses contain two and three transactions. Each arm used the same witness bytes, the same 17,259-word program from the Apollo 0.20.0-rc.1 OS integration, and a fresh execution-mode VM for each job. The parent measured request through completed reply. Each process retained its prepared OS program. On each rotation it ran A, A, B, A with both directions represented. The first two requests expose initial work and immediate reuse. The third measures a different real witness. No capture, RPC, block execution, class compilation or node witness assembly runs inside the timer.

| Second job, median wall | Reference Rust | In-process OxCairo | Guarded OxCairo | Paired Rust / in-process | Paired Rust / guarded |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16,000,001 stored | 142.95 ms | 51.02 ms | 74.33 ms | 2.82× | 1.99× |
| 16,149,540 stored | 346.80 ms | 120.61 ms | 175.54 ms | 2.82× | 1.93× |
| 16,000,001 standard DEFLATE | 557.15 ms | 435.59 ms | 444.60 ms | 1.25× | 1.25× |
| 16,149,540 standard DEFLATE | 1,381.68 ms | 1,340.39 ms | 1,133.37 ms | 1.07× | 1.19× |

These are six paired second-job observations per stored row and three per DEFLATE row, on a shared macOS M4 Max. Ratios are medians of paired elapsed times. The Rust arm uses its production instruction cache, streaming BLAKE2s, dense relocation and Pathfinder Pedersen options. The complete production SNOS entry point decodes the supplied JSON, initializes and executes a new VM, finalizes and extracts a CairoPie. The stored Rust fixture streams its existing encoding in 32,768-record batches. The standard DEFLATE arm uses its existing unmerged ZIP writer. The in-process OxCairo arm calls the supplied witness benchmark and retains its bounded class cache across jobs. The guarded arm pins the packed program by SHA-256, forks a child per job, enforces limits, hashes and durably publishes the result. Rust and the in-process diagnostic complete after closing the output. They carry no matching job guard or durability contract. These comparisons do not establish a node's end-to-end speedup or behavior at larger transaction counts.

The stored profile's first job after process readiness took 140.56 / 353.80 ms on Rust, 59.68 / 149.21 ms on in-process OxCairo and 73.00 / 190.52 ms on guarded OxCairo, small/large respectively. Charging each process its launch-to-ready and first-job intervals gives 195.79 / 412.96 ms, 69.72 / 158.45 ms and 85.76 / 212.63 ms. Launch-to-ready includes OS startup, runtime and one-time program preparation. The harness interleaves the arms and excludes time spent waiting for the other arms to run.

| Stored OxCairo phase in second in-process job | 16,000,001 | 16,149,540 |
| --- | ---: | ---: |
| Witness read and VM initialization | 12.06 ms | 20.01 ms |
| Execution, including hints and builtins | 18.11 ms | 46.48 ms |
| Finalization | 5.22 ms | 7.63 ms |
| PIE member construction, memory encoding and writing | 14.89 ms | 46.45 ms |

The first job after switching to the other witness took 52.85 / 142.52 ms for in-process OxCairo, 73.88 / 184.89 ms for guarded OxCairo and 139.83 / 352.78 ms for Rust. Interpreting a same-witness second job as typical consecutive node blocks would overstate class-cache reuse.

All 216 outputs matched a retained independent oracle for the four canonical JSON members and the exact memory member. Each fixed profile and arm also produced one archive SHA-256 per block. Standard DEFLATE produced identical ZIP bytes across engines. Stored archives used different container headers while yielding identical content. Stored outputs were 30,109,352 and 84,270,734 bytes. Standard DEFLATE outputs were 3,959,832 and 10,491,398 bytes.

The raw files include all rotations, admissions, timings, phases and per-output archive receipts. The ordinal is one-based. Full-archive verification and content checks were outside the timers. Presence of a digest in a success response is separately checked against the file on disk. All inputs used JSON. The witness binary encoding is a separate experiment.

- [Stored samples](stored.jsonl)
- [Standard DEFLATE samples](standard.jsonl)
- [Canonical member SHA-256](members.json)
- [Executable and input identities](identities.txt)
