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
