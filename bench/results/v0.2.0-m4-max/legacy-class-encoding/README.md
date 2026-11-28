# Legacy Cairo class string serialization

Both OCaml profile-guided builds ran the same 70 native OS witnesses on a 36 GiB Apple M4 Max. Five rounds shuffled the case and engine order, with one sequential pair per case per round. The baseline is the packaged `f6e37bd` runtime. The candidate `89f3c0a` batches plain ASCII spans and matches the pinned sequencer’s escaping of non-ASCII strings used in hinted class hashes. Every invocation matched the saved stock sequencer digest for its public output.

| Mode | Paired runs | Median per-case speedup | Ratio of summed case medians |
| --- | ---: | ---: | ---: |
| [Cold CLI](cold-checkpoint.csv) | 350 | 0.996× | 1.005× |
| [Warm shuffled worker](worker-checkpoint.csv) | 350 | 1.005× | 1.012× |

Cold runs launch a fresh process with the complete compiler JSON. Each warm worker keeps its compiler loaded and executes a fresh VM per request. Individual ratios divide baseline elapsed time by candidate elapsed time. The per-case statistic takes the median within each case and then across all 70 cases. In the warm comparisons, `test_cairo0_proven_revert` gained 1.062× and `test_deprecated_call_contract_variants` gained 1.081×. These were the two middle workloads in the packaged baseline’s cold comparison against stock Rust.

An independent test compiled the pinned Rust `PythonJsonFormatter`, passed one string containing every Unicode scalar value through serde_json’s full serialization path, and compared the complete bytes to the OCaml encoder. Both produced 12,963,344 bytes with SHA-256 `906b9a46edf22395b9eb06ac53081e8edfebae129b01978410ae0c22faa1c178`. The regression tests also cover malformed UTF-8, empty strings, control characters, raw DEL, space-padded BMP escapes and supplementary surrogate pairs. [Binary and data identities](manifest.json)
