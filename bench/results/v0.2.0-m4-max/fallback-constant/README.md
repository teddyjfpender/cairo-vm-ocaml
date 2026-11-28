# Fallback constant lookup

The VM first resolves a constant in the hint’s accessible scopes. When that lookup fails, the fallback walks the identifier table in its original order. Candidate `ac12c69` stops the walk as soon as it finds the first matching constant with a value. The change was integrated as `db2bfe6`. Both profile-guided executables were measured against the preceding `89f3c0a` build on a 36 GiB Apple M4 Max with other work running.

| Mode | Matched pairs | Median per-case speedup | Ratio of summed case medians |
| --- | ---: | ---: | ---: |
| [Cold CLI](cold-checkpoint.csv) | 350 | 1.023× | 1.022× |
| [Warm shuffled workers](worker-checkpoint.csv) | 350 | 1.023× | 1.023× |

Five rounds each visited all 70 upstream cases in shuffled order. Engine order was randomized within each pair. The cold commands launched a fresh process with the complete compiler JSON. Each warm worker retained its compiler and ran a fresh VM per request. Every run matched the saved stock sequencer output digest. The per-case statistic takes the median ratio within each case and the median across cases. The suite ratio sums each engine’s case medians before division.

Both CLIs passed the strict execution, output PIE, replay, proof, Stwo and malformed-input comparisons, including four reviewed replay rejections. [Strict suite results](strict.txt) · [Program and binary hashes](manifest.json)
