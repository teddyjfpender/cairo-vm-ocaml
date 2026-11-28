# Cold and warm native OS qualification for 9022555

On the 36 GiB Apple M4 Max, five rounds compared 70 distinct upstream scenarios with the pinned stock Rust sequencer. Each cold round shuffled cases and the order of three fresh processes. Rust executed its embedded compiler, and both OCaml processes loaded the identical full 52,471,230-byte compiler JSON. The baseline OCaml binary was the earlier `f6e37bd` package. The new PGO binary was built at `762e250`, whose runtime sources are identical to integrated commit `9022555`. All cold outputs matched the stock Rust digest. In the warm comparison, each process retained its compiler and handled five shuffled traversals of all 70 inputs, validating public output on every pair.

| Workload and reference | Pairs | Reference sum | New sum | Total ratio | Median per case | Cases ≥10× |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [Cold, stock Rust](timings.csv) | 350 | 28.624 s | 2.142 s | 13.364× | 3.660× | 19/70 |
| [Cold, prior OCaml](timings.csv) | 350 | 2.391 s | 2.142 s | 1.116× | 1.115× | 0/70 |
| [Warm shuffled, stock Rust](shuffled.csv) | 350 | 4.974 s | 0.845 s | 5.890× | 5.180× | 0/70 |

The total ratio divides the sums of per-case median elapsed times. The median per case gives equal weight to each scenario’s median paired speedup. In these same cold rounds the earlier OCaml binary measured 3.306× median and 11.971× total against Rust. All 70 scenarios improved over that OCaml binary in the matched comparison.

The macOS arm64 tarball’s SHA-256 is `77ade018db0b43a4bbd44af3b210bae0bd04c715c7b16e9c46a52581cd0217aa`. The packaged CLI, two worker requests and C ABI smoke cases passed. The strict generic, proof, replay and malformed-input checks passed. [Package smoke](package.txt) · [Strict parity](strict.txt) · [Binary and package digests](manifest.json)
