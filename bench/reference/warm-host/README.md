# Warm host phase attribution

This diagnostic uses a packed execution-mode program, full trace recording, secure finalization and an unmerged stored Cairo PIE. An isolated native build records exclusive elapsed time with a monotonic clock. The uninstrumented workers should be used for comparative performance. Timers in hot code add overhead.

Apply the patch in a disposable worktree of b23d04148e09b473a3ca11411b1ae50a80b67a39, build the native worker and run the paired driver. The input order is block 16,000,001 followed by 16,149,540. Each height gets six independently started processes, with the identical witness submitted twice to each process. The driver alternates heights by round. Output files are overwritten between rounds. The supplied packed program SHA-256 was e3ec597c011f51959f393dad2aca33f943b068031cac0f6a4fe6ad3f1a7c04b0.

```sh
git apply bench/reference/warm-host/phase-clocks.patch
dune build --profile release bench/supplied_pie.exe
rustc -O bench/reference/warm-host/measure_stages.rs -o /tmp/measure_stages
mkdir measured-jobs
/tmp/measure_stages _build/default/bench/supplied_pie.exe program.packed small.json large.json measured-jobs
```

| Exclusive interval, milliseconds | 2 tx, first | 2 tx, second | 3 tx, first | 3 tx, second |
| --- | ---: | ---: | ---: | ---: |
| Witness file read and initial decode | 11.89 | 5.73 | 17.38 | 8.24 |
| Runner setup | 5.61 | 6.43 | 15.01 | 11.22 |
| Cairo instruction stepping and dispatch | 8.42 | 7.61 | 29.16 | 22.70 |
| Hint handlers, including lazy witness materialization | 12.51 | 12.82 | 29.33 | 34.44 |
| Builtin deduction | 1.00 | 0.40 | 1.58 | 0.87 |
| Secure finalization, exclusive of separately timed deductions | 5.00 | 4.98 | 7.16 | 7.18 |
| PIE memory encoding | 1.19 | 1.10 | 3.02 | 3.07 |
| Stored member payload writes | 13.45 | 19.48 | 44.36 | 42.26 |
| Other archive work including CRC, metadata, headers and close | 9.45 | 9.28 | 16.18 | 15.35 |

On this macOS arm64 machine the external launch-to-ready median was 7.75 and 7.79 ms; packed program loading and image preparation accounted for 4.53 and 4.59 ms inside those intervals. The second request reused the program. These are benchmark-worker phase measurements. The guarded host also isolates requests and publishes durably. The raw rows retain integer nanoseconds. Each phase column reports its own median.

Instruction stepping includes operand reads, inline checks, cache lookups and register updates. Builtin deduction covers the OCaml deduction path and native bitwise, Pedersen and Poseidon computation; inline range checks stay in stepping. Witness time includes the initial file read, validation and parse. Deferred transaction/class work stays with the phase that requests it. Payload writes measure buffered output calls on this filesystem. Other archive work includes close and its final flush. Each retained first and second output matched the existing stored reference ZIP (30,109,352 and 84,270,734 bytes).
