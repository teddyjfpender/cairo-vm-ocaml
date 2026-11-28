# Typed compiler input and parallel debug validation

The regular-release candidate at `a28367a` contains the typed decoder at `62569dc`. Compared with `d884acc`, it achieved **1.148× median fresh-process wall speedup** and **1.104× median child CPU speedup** on the 70-scenario OS corpus. All 70 case medians improved on both measures. Wall speedup ranged from 1.061× to 1.232×. All 630 pairs returned byte-identical stdout, and each normalized output matched its retained Rust oracle. One-minute load ranged from 4.61 to 5.74 on this 14-core M4 Max.

| Focused workload | Pairs | Baseline median ms | Candidate median ms | Median paired speedup |
|---|---:|---:|---:|---:|
| genesis | 25 | 25.57 | 21.08 | 1.211× |
| Cairo0 | 25 | 38.41 | 32.42 | 1.187× |
| Cairo1 | 25 | 36.77 | 32.43 | 1.138× |
| transfer1024 | 25 | 169.82 | 163.43 | 1.036× |
| storage8192 | 13 | 872.80 | 883.35 | 0.990× |

The independent four-way series ran all four variants in randomized order, five times per scenario. The 70-case median wall / CPU ratios were 1.004× / 0.997× for partitioning alone, 1.062× / 1.093× for typed decoding alone, and 1.146× / 1.095× for both changes. An isolated validator measurement on the full 44 MB debug object took 7.96 ms serially and 4.37 ms with the bounded partition, using the median of 31 calls per binary.

Both revisions read the identical 52,471,230-byte compiler JSON, SHA-256 `2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded`. The baseline and candidate executable SHA-256 values were `4d496b68eea0f971505c1b85faec8ae8a603c29007f5ea54eb8782c293f50f96` and `9950c073d2dc30f6a5d2483b7200a9324bac308cb05fb6dc6f44bf49313f3d95`. Each process ran `PROGRAM --layout all_cairo --print_output --os_hints WITNESS`. Filesystem caches were warm. The process timer included startup, complete parsing and validation, execution, output and exit.

Run `dune build --profile release -j1 bin/main.exe` at each revision and save its executable. Given the 70 upstream witness JSON files, reproduce the paired run with the following command from this directory.

```sh
python3 compare.py BASE_CLI CANDIDATE_CLI RAW_PROGRAM WITNESS_DIRECTORY NEW_RECEIPT.csv
```

Run `dune runtest --profile release -j1` and `python3 test/fixtures/os/check.py CANDIDATE_CLI RAW_PROGRAM` from the repository root. All 25 native fixtures matched every retained PIE member and applicable public output. The original compiler source also produced byte-identical packed images. A differential run on 608 generated complete or malformed inputs matched exits, diagnostics, stdout and packed bytes, with 145 accepted and 463 rejected. Another 42 cases covered real malformed compiler locations, fallback spellings and chunk boundaries.

[Corpus pairs](scenarios.csv), [focused pairs](focused.csv), and [component comparisons](components.csv) retain elapsed and CPU seconds. The median reported for each case is the median of its individual paired speedups. The suite statistic is the median of those 70 case medians.

The integrated release PGO build at `16aa093` also completed five shuffled traversals with independently warmed Rust and OCaml workers. All 350 requests matched the Rust public output. The median paired scenario speedup was 4.79× and the case medians summed to 5.10 s Rust and 0.93 s OCaml (5.48×). No scenario's median reached 10× in this warm run. The process startup, compiler decoding and initial worker warm-up precede the timing interval. The samples are in `shuffled-worker.csv`.

A fresh proof-mode exporter built from the same runtime generated the exact input digests of all ten previously verified Stwo proofs, including both direct raw OS programs.

The same packaged PGO build ran five paired cold comparisons on each of 22 scaled OS workloads. 20 reached 10×. Across these cases the median paired speedup was 11.51× and the summed-time ratio was 12.40×. The two repeated-storage cases measured 9.54× at 4,096 invokes and 9.05× at 8,192. The 9,216-transaction rollback case measured 10.01×. The three `pgo-scaled-*.csv` files record all 110 pairs and identify the stock and memory-bounded checked sequencer runners.
