# macOS OS host startup on Apollo genesis

Each observation starts a fresh installed host and includes interpreter startup, compiler snapshot and pin check, process supervision, native execution, output verification, and atomic publication. The input was already available on disk. The checkout ran on a shared Apple M4 Max under macOS 15.3.1.

| Host interpreter | Baseline median | Candidate median | Median paired speedup | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Apple Python 3.9.6 | 89.22 ms | 75.86 ms | 1.171× | 40/40 |
| Homebrew Python 3.14.6 | 91.51 ms | 78.04 ms | 1.173× | 40/40 |

[Raw elapsed times](pairs.csv) cover two batches per interpreter. Each batch discarded two warmup pairs, then alternated baseline-first and candidate-first across 20 measured pairs. Each invocation used a fresh output directory. A monotonic timer surrounded the entire host subprocess. After each invocation the harness checked successful exit, the reported digest, and an independent SHA-256 of the complete published archive. All 160 measured outputs matched stock Rust, as did all 16 warmup outputs.

The package baseline host matched the script at `df6eecbc1e0b9347f1eebe72353a185654848b6a`. The candidate installed the script at `36fa848333c0c163ae8e6282fc5db96c37de4877` beside the identical native CLI. Both used host protocol v1, default operator limits and standard merged publication. Both can be exercised with the Apollo request and fixture construction in [the package smoke test](../../../scripts/smoke_release.py). These timings cover host startup and publication on this small local fixture. RPC/state preparation, proving and mainnet workloads require separate measurements.

| Input or artifact | SHA-256 |
| --- | --- |
| Baseline macOS arm64 package | `60301f99f26f6575317972eb709eef348b007d03f74dfaa4133b9e1ae205b936` |
| Installed native CLI, both arms | `63541a7db24ebbdf16901e156c033eaa6720b70332f63bddecf0169a729954d7` |
| Apollo compiled OS | `794c90c23d0beda4f34bd061e34c726ddff95bf1eebb441ee2ea9af1951f3c67` |
| Genesis witness | `cb6a4a296feba044f54cf4b0258ca52bb9cf08042f0cc5a1e7f467bd3b47fac0` |
| Complete Rust-profile ZIP | `b78c75c541cdd948d1d7603d41103aa3f6ceb8ae505630a4f3cbe3e791f47bd7` |
