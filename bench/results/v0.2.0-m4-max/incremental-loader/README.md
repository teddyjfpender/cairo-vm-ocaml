# Incremental cold compiler loader benchmark

The 70-scenario median improvement was **1.099×** over the preceding OCaml loader. The 70 case-level paired medians ranged from **1.050× to 1.213×**. Each scenario ran in five fresh-process pairs. Every pair produced identical stdout.

Both executables used the ordinary Dune release profile on an Apple M4 Max running macOS 15.3.1. The base was `e559436e2589f1a10ce4fc6b3dac7a1cdbf4379c`. The candidate was `eaae51e68df17494c2b178b9176e8cf02b29e3a6`, integrated as `fc1ba5353aefe6b73a912aaf84bc7bc81017a22b`. The baseline and candidate executable SHA-256 values were `f83e50706613bbd3f4edc7bcb8c66dc03ff97c3ffc8dbd75b66b30d3d00f3b2a` and `e6345dc5430fe7d87713351b1bc7b8277b5831453415d0e98ee2f5fa0b59e5af`.

Each run used the same 52,471,230-byte compiler JSON with SHA-256 `2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded`. Python measured elapsed process wall time with `time.perf_counter()` around this command and collection of its stdout.

```sh
cairo-vm-cli PROGRAM --layout all_cairo --print_output --os_hints WITNESS
```

Filesystem caches were allowed to remain warm and other local projects continued running. Scenario order was shuffled in each round. The CLI order in each scenario pair alternated by case index plus round number. In the separate focused series, CLI order alternated by round. For each case we calculated the median of the individual baseline-to-candidate time ratios. The corpus summary is the median of those 70 case medians.

| Focused case | Pairs | Baseline median ms | Candidate median ms | Median paired speedup |
|---|---:|---:|---:|---:|
| genesis | 25 | 42.13 | 35.65 | 1.187× |
| Cairo0 | 25 | 63.23 | 64.13 | 1.073× |
| Cairo1 | 25 | 56.36 | 50.61 | 1.112× |
| transfer1024 | 25 | 204.96 | 206.57 | 1.021× |
| storage8192 | 13 | 882.80 | 886.70 | 0.988× |

The Cairo0 and Cairo1 cases are the two middle scenarios from the preceding 70-scenario cold comparison. They use the upstream trivial-diff workload with KZG disabled and full output enabled. The transfer case has 1,024 transfers across 16 recipients. The storage case has 8,192 operations.

[All scenario pairs](scenarios.csv) and [focused pairs](focused.csv) record process wall seconds. [Witness identities](witnesses.csv) identifies each exact input. The native OS fixture suite separately compared all 25 saved upstream PIE member sets and available public outputs using the same full program.

## Second loader candidate against the integrated runner

The integrated regular-release baseline was `43598c9a4d9ee63a8844b34b12d54a0b3f634e49`. The candidate was `d884acca5e5386899490bd7ba320e034201c5906`. Both include the prior loader improvement and execution changes. Executable SHA-256 values were `0b2bfa612ed55b442233b0966140eb09bbff07b5b2381c44e0ac11ab636f36c3` and `4d496b68eea0f971505c1b85faec8ae8a603c29007f5ea54eb8782c293f50f96`. The program, witness identities and CLI were the same as above.

| Integrated corpus series | Pairs | Median case wall speedup | Total wall speedup | Cases faster | Median case child CPU speedup |
|---|---:|---:|---:|---:|---:|
| First run | 350 | 1.011× | 0.995× | 40/70 | Unmeasured |
| Independently shuffled recheck | 630 | 1.014× | 1.011× | 41/70 | 1.009× |
| Lighter-load recheck | 490 | 1.064× | 1.064× | 68/70 | 1.057× |

Both executables produced byte-identical public output in every pair, and each corpus output matched the retained Rust field-element digest. Each digest uses 32-byte big-endian field elements reduced modulo the Cairo prime. Case order was shuffled every round, and first engine alternated by case index plus round. The recheck also measured the child's cumulative user and system CPU time. One-minute host load sampled at the start of each recheck round ranged from 17.1 to 18.6 on 14 logical CPUs. The first and second series had per-case median paired wall ranges of 0.756–1.380× and 0.811–1.283×.

| Focused case | Pairs | Baseline median ms | Candidate median ms | Median paired speedup |
|---|---:|---:|---:|---:|
| Genesis | 25 | 47.56 | 41.51 | 1.181× |
| Cairo0 | 25 | 67.35 | 67.43 | 0.955× |
| Cairo1 | 25 | 67.23 | 65.04 | 0.999× |
| Transfer 1024 | 25 | 235.29 | 229.97 | 1.004× |
| Storage 8192 | 13 | 1,348.06 | 1,347.50 | 1.041× |

[First 70-scenario run](integrated-scenarios.csv), [independent recheck](integrated-recheck-scenarios.csv), and [focused pairs](integrated-focused.csv) contain the raw seconds, order and output digest. All 25 native OS fixtures matched saved sequencer PIE members and available public outputs. Six malformed copies of the full source produced identical exit statuses and error text on both binaries. The loader test suite exercised false boundaries, reentrant conversion and consumer exceptions.

### Component comparisons

Four ordinary-release variants shared the integrated execution code. `none` uses the preceding loader, `life` defers debug-worker termination until conversion, `reuse` applies exact repeated-span validation and reuses parsed bytecode words, and `both` combines these changes. The latter two include the reference-expression table sizing adjustment. Every variant retained the original identifier table size.

| Variant vs preceding loader | Program load only, wall / child CPU | 70-scenario E2E, wall / child CPU |
|---|---:|---:|
| Worker lifetime | 0.940× / 1.041× | 0.996× / 1.000× |
| Span and word reuse | 1.026× / 1.019× | 1.037× / 1.031× |
| Both | 1.022× / 1.028× | 1.040× / 1.033× |

The load-only CLI applied the runner's standard OS GC configuration, loaded the same complete JSON through `Program.load_file`, and emitted the program's data, reference and identifier counts. Each of 31 blocks ran all four variants in shuffled order. The E2E comparison ran three four-variant blocks per scenario, with a fresh shuffled engine order per block. Each process emitted the expected Rust output. This diagnostic series uses independent randomized runs, so its estimates differ from the longer two-engine comparisons. [Load-only samples](factorial-program.csv) and [E2E samples](factorial-e2e.csv).

### Lighter-load replication and integration controls

Under lighter host load, the same integrated binaries showed a **1.064× median E2E wall speedup** across the same 70 scenarios. Six hundred thirty pairs at higher load had shown 1.014×. The seven-round lighter run recorded 1.056× total child CPU speedup, and every scenario reduced median child CPU time. The per-case median wall speedup range was 0.995–1.146×. One-minute host load measured at the start of each round ranged from 9.36 to 10.46. Every output matched the retained Rust digest. [All 490 lighter-load pairs](integrated-lighter-scenarios.csv).

| Variant vs preceding loader | Lighter program load only, wall / child CPU | Lighter 70-scenario E2E, wall / child CPU |
|---|---:|---:|
| Worker lifetime | 1.043× / 1.039× | 1.039× / 1.022× |
| Span and word reuse | 1.060× / 1.067× | 1.033× / 1.037× |
| Both | 1.092× / 1.092× | 1.064× / 1.060× |

The component run repeated the same 31 load-only blocks and three four-engine blocks per scenario with a new shuffle. Observed one-minute load during the 70-scenario component series ranged from 7.35 to 8.99, compared with 15.66–19.81 during the earlier component series. [Load-only samples](light-factorial-program.csv) and [E2E samples](light-factorial-e2e.csv).

A separate diagnostic shuffled seven executables within each case and round. All 1,470 public outputs matched Rust. Each ratio below is the median of 70 case medians across three rounds. In the CSV, `old_base` and `old_final` refer to `eaae51e` and `c9d3613` before integration, while `base` and `final` refer to `43598c9` and `d884acc`. Two `nohash` builds disabled speculative class hashing during witness preparation, and `wide` restored the experimental larger identifier table. The release candidate preserves the original identifier table's traversal order for ambiguous unqualified constants.

| Matched diagnostic comparison | Wall speedup | Child CPU speedup |
|---|---:|---:|
| Loader-only branch before integration | 1.081× | 1.093× |
| Integrated candidate | 1.053× | 1.055× |
| Integrated candidate with class hashing disabled on both sides | 1.055× | 1.059× |
| Larger identifier table relative to integrated candidate | 1.019× | 1.025× |

Seventeen of 70 witnesses contained an eligible deprecated-class hash chain. The integrated wall speedup was 1.039× on those cases and 1.059× on the other 53. [Seven-engine diagnostic samples](crossprobe.csv).
