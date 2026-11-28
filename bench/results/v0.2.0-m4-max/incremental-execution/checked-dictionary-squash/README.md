# Checked dictionary squashing on M4 Max

Nine alternating fresh-process pairs compare ordinary release builds of afc9719 and 2322087. Both CLI processes loaded the full unprepared compiler JSON and the same block witness, securely finalized, printed public output and exited. Per-pair stdout matched byte for byte. Case order was shuffled with seed 1212 and the first binary alternated across cases and rounds. Other projects continued running on the same host.

| Workload | Baseline median | Candidate median | Median of paired baseline/candidate ratios |
|---|---:|---:|---:|
| 8,192 repeated storage invokes | 0.809 s | 0.782 s | 1.026× |
| 9,216 mixed successful and reverted transactions | 0.815 s | 0.789 s | 1.037× |
| 8,192 ERC20 transfers | 1.007 s | 0.971 s | 1.039× |
| 4,096 scattered writes | 0.852 s | 0.829 s | 1.013× |

The median of the four paired scenario ratios is 1.031×. Summing the four per-scenario median times yields 1.034×. The candidate ran faster in all 36 pairs. These measurements compare the two OCaml builds. No release PGO build or new Rust speedup was measured here.

The paired-times.csv file contains all wall times in seconds. The inputs.csv file identifies the executables, compiler and witnesses. The command for either binary was CLI COMPILER --os_hints WITNESS --layout all_cairo --print_output. The memory.csv file records separately requested complete relocated memory files, public stdout and steps, which all matched. The public-words.csv file records 70 distinct upstream witnesses and their pinned Rust, cold native and shuffled persistent-worker public-word SHA-256 digests. Digests in this file use big-endian 32-byte fields.

An instrumented ordinary build of the same row algorithm at 721c1f5 measured 213,058 committed rows across 367 accepted primitive entries on the storage workload and 225,848 across 1,835 on mixed reverts. Each row executes nine guest instructions. Streaming covers about 3.7% and 4.3% of those respective guest instruction counts.

The native archive comparison passed all 25 main OS witnesses, four Virtual OS witnesses, and 13 aggregator configurations against pinned sequencer PIE hashes. The archive checkers also exercised malformed syscall reads, Virtual OS gas tracking and blob output. The differential tests passed with dune runtest --profile release -j1.
