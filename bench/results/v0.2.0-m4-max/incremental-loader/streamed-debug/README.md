# Streaming strict compiler debug validation

The regular-release binary at `ef27378` was **1.061× faster** than `cf54a205` on the median upstream scenario. Median peak resident memory fell from **90.60 MiB to 62.07 MiB**. The 70 scenarios each ran in nine alternated, fresh-process pairs with identical raw compiler and witness bytes. Every pair matched its stored Rust public output digest. Individual median wall ratios ranged from 1.003× to 1.189×, and the median child CPU ratio was 1.078×. The one-minute load ranged from 5.22 to 7.54 on the 14-core M4 Max.

| Workload | Pairs | Base median ms | Streamed median ms | Median paired wall speedup | Base median peak MiB | Streamed median peak MiB |
|---|---:|---:|---:|---:|---:|---:|
| Genesis | 25 | 18.06 | 17.05 | 1.053× | 72.94 | 35.00 |
| Cairo0 middle case | 25 | 31.57 | 30.74 | 1.019× | 90.22 | 57.44 |
| Cairo1 middle case | 25 | 29.53 | 28.85 | 1.042× | 90.59 | 62.48 |
| Transfer1024 | 11 | 151.6 | 149.2 | 1.018× | 207.63 | 168.75 |
| Storage8192 | 11 | 808.4 | 808.4 | 1.003× | 715.97 | 670.19 |
| Full compiler to packed program | 25 | 25.66 | 22.47 | 1.146× | 74.88 | 35.50 |

The first five rows include complete OS initialization, execution, output and process exit. The last row loads and packs the full 52,471,230-byte compiler program to a temporary file, then checks all packed image bytes by SHA-256. Filesystem caches were warm. Median wall ratios use each pair directly. The corpus aggregate takes the median of the 70 scenario medians. Peak memory comes from Darwin's per-process `wait4` result.

## Validation and fallback

On this compiler, two native workers use bounded positional reads to validate a 44 MB debug object while the OCaml parser consumes the rest of the file. Each worker holds at most 2 MiB plus 128 KiB of overlap. The workers check each numeric map key, full instruction and embedded JSON. Both adjacent readers must reach the same absolute separator offset. The outer document must identify the skipped span as its root debug value, and file size and nanosecond modification/change timestamps must survive all reads. Packed inputs, small files, other JSON layouts and unsuccessful fast validation retain the general loading path.

All 25 OS fixtures, four virtual OS fixtures, and 13 aggregator configurations matched the pinned sequencer digests. The release test suite passed, including direct checks with nested garbage collection, a raising callback, a same-size source rewrite, and a truncated descriptor. A separate full-source differential compared exit status, stdout, stderr and the output image on the original compiler and 36 variants. These cover corrupted separators at all 21 interior tile boundaries, numeric overflows on either side, escaped field names, duplicate hints, and a misleading nested debug key. Another 267 targeted and 608 deterministic arbitrary/malformed document comparisons matched. The full compiler packed to `a48576085fe533b27f82a45c149db20751e001fac9d7bd5d39fc0623a8c3b21c`.

## Reproduction

Build the two revisions with the same compiler using `dune build --profile release -j1 bin/main.exe`. Run `python3 compare.py BASE CANDIDATE RAW_PROGRAM WITNESS_DIRECTORY RECEIPT.csv` from this directory. It verifies the compiler and witness hashes, reproduces the 70-case process order and checks output digest parity. The tested executables had SHA-256 `a0341f35107f041c551192b521843c1a3c06cbc082f602f543a57fc574446120` and `36aa6e15b4888c9cdc632ca1d4347e3453fd489bc01a09165d150babae5ec099`. These receipts isolate the streamed loader. They use ordinary release compilation and exclude later changes to legacy-class preparation.
