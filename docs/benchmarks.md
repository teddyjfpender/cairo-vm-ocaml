# Benchmarks

Detailed measurements, newest first. Each section names the machine, the Rust version
and the method. Raw paired timings live in [`bench/results/`](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/).

## Apple M5 Max, Rust cairo-vm v4.0.0 (main at de7216b)

Best of three wall-clock runs per program, `--layout all_cairo --print_output`, same
compiled programs for both CLIs; every row's stdout (and, when traced, trace and memory
files) matched byte-for-byte.

**Execution and printed output**

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.554 | 0.110 | 5.05× |
| big_fibonacci | 0.489 | 0.088 | 5.55× |
| blake2s_integration_benchmark | 0.603 | 0.139 | 4.33× |
| compare_arrays_200000 | 0.559 | 0.068 | 8.25× |
| dict_integration_benchmark | 0.482 | 0.143 | 3.36× |
| integration_builtins | 0.775 | 0.113 | 6.83× |
| keccak_integration_benchmark | 0.773 | 0.183 | 4.22× |
| linear_search | 0.572 | 0.069 | 8.26× |
| math_cmp_and_pow_integration_benchmark | 0.594 | 0.119 | 5.00× |
| math_integration_benchmark | 0.544 | 0.098 | 5.52× |
| memory_integration_benchmark | 0.393 | 0.087 | 4.52× |
| operations_with_data_structures_benchmarks | 0.566 | 0.091 | 6.21× |
| pedersen | 0.236 | 0.023 | 10.08× |
| poseidon_integration_benchmark | 0.340 | 0.195 | 1.75× |
| secp_integration_benchmark | 0.718 | 0.470 | 1.53× |
| set_integration_benchmark | 0.306 | 0.039 | 7.85× |
| uint256_integration_benchmark | 0.732 | 0.171 | 4.28× |
| **Total** | **9.236** | **2.208** | **4.18×** |

**Execution, printed output, trace and memory files**

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.697 | 0.147 | 4.73× |
| big_fibonacci | 0.610 | 0.123 | 4.96× |
| blake2s_integration_benchmark | 0.576 | 0.134 | 4.29× |
| compare_arrays_200000 | 0.681 | 0.106 | 6.43× |
| dict_integration_benchmark | 0.503 | 0.171 | 2.94× |
| integration_builtins | 0.765 | 0.129 | 5.93× |
| keccak_integration_benchmark | 0.701 | 0.162 | 4.32× |
| linear_search | 0.701 | 0.114 | 6.17× |
| math_cmp_and_pow_integration_benchmark | 0.623 | 0.137 | 4.53× |
| math_integration_benchmark | 0.557 | 0.121 | 4.62× |
| memory_integration_benchmark | 0.452 | 0.118 | 3.85× |
| operations_with_data_structures_benchmarks | 0.561 | 0.111 | 5.06× |
| pedersen | 0.201 | 0.028 | 7.06× |
| poseidon_integration_benchmark | 0.287 | 0.149 | 1.93× |
| secp_integration_benchmark | 0.624 | 0.356 | 1.75× |
| set_integration_benchmark | 0.258 | 0.042 | 6.17× |
| uint256_integration_benchmark | 0.794 | 0.186 | 4.28× |
| **Total** | **9.589** | **2.333** | **4.11×** |

Traced runs of the largest CPU-bound programs are bounded by the filesystem: big_fibonacci
writes 688 MB of trace and memory, which takes about 0.1 s at the ~7 GB/s this machine
sustains for any write strategy (buffered, `write`, `mmap`; concurrent writers do not help).

## Linux x86-64, Rust cairo-vm 3.2.0: native instruction batches

The installed OxCaml release was **2.99× faster for execution** and **3.91× faster
with trace and memory** than Rust cairo-vm-cli 3.2.0 on its 17 CairoZero
benchmarks. The full suite target is 10×. Each comparison uses the sum of
per-program medians from four alternating pairs, with both VMs on the same
CPU core, secure execution enabled and Rust delegation disabled.

| Workload | Rust | OCaml | Speedup |
| --- | ---: | ---: | ---: |
| Execute and print output | 19.42 s | 6.50 s | 2.99× |
| Execute, print, and write trace and memory | 52.56 s | 13.45 s | 3.91× |

The traced runs matched stdout and both binary artifacts on every pair.
Across the suite the VMs executed 117,043,195 steps and wrote 2.81 GB of trace
and 4.37 GB of relocated memory. The upstream Pedersen benchmark measured
11.46× for execution, with 13.54× in a separate twelve-pair check.
Against the preceding OCaml release (#33), the execution suite went from
9.86 s to 5.66 s on the same machine (1.74×).

The [repeated Pedersen node fixture](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/pedersen_repeated_nodes.cairo)
cycles through 16 input pairs across 8,192 distinct builtin instances and
includes every computed hash in its printed output. With full artifacts it ran
in 23.3 ms versus 333.7 ms for Rust (14.32×).
Varying the second input of the upstream Pedersen benchmark by its iteration counter measured 2.79× with artifacts.

[Execution pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-exec.csv) ·
[Traced pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-traced.csv) ·
[OCaml revision pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-parent.csv) ·
[Hash workload pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-hashes.csv) ·
[Pedersen recheck](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-pedersen.csv) ·
[Artifact sizes](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/native-kernel-output-bytes.csv)

To check the 10× target, pass `--min-suite-speedup 10` to
`bench/compare_cli.py`. The harness checks output equivalence before
evaluating the threshold. Raw timings remain on stdout.

## Linux x86-64, Rust cairo-vm 3.2.0: previous baseline


| Mode | Rust | Native OCaml | Speedup | Programs faster |
| --- | ---: | ---: | ---: | ---: |
| Execution and printed output | 16.65 s | 8.38 s | 1.99× | 17/17 |
| Execution, printed output, trace and memory | 50.13 s | 15.14 s | 3.31× | 17/17 |

Each total sums the per-program median of four paired process wall times. Both
release binaries used the same CPU affinity within a comparison, the default
secure execution settings and the same cairo-lang 0.13.5 inputs. The harness
alternated which VM ran first and checked stdout and every requested artifact
after each pair. The machine reported an Intel Xeon Platinum 8573C. Rust used
its default allocator feature and the OCaml executable ran with delegation
disabled. Raw pairs: [execution](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/rust-3.2.0-run.csv) and
[trace and memory](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/rust-3.2.0-traced.csv).

The targeted [Keccak byte-prefix workload](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/keccak_byte_prefixes.cairo)
queries 4,096 increasing, non-word-aligned lengths from one immutable Cairo
array. Eight alternating traced pairs measured 0.825 s for Rust and
0.038 s for OCaml (21.9×). A separate paired comparison against the preceding
OCaml revision measured 1.359 s and 0.024 s (56.7×). These ratios apply
to repeated prefixes. [Rust pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/keccak-byte-prefixes-vs-rust.csv)
and [parent pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/keccak-byte-prefixes-vs-parent.csv).

## Apple M5 Max, Rust cairo-vm 3.2.0 (main after #33)

Apple M5 Max under background load, best of 3 wall-clock runs, `--layout all_cairo --print_output --trace_file … --memory_file …`
for both binaries. Every row's stdout, trace file and memory file were compared byte-for-byte.

| program | rust (s) | ocaml (s) | speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.861 | 0.242 | 3.56x |
| big_fibonacci | 0.725 | 0.319 | 2.28x |
| blake2s_integration_benchmark | 1.293 | 0.546 | 2.37x |
| compare_arrays_200000 | 1.690 | 0.498 | 3.40x |
| dict_integration_benchmark | 2.061 | 0.920 | 2.24x |
| integration_builtins | 2.916 | 0.809 | 3.60x |
| keccak_integration_benchmark | 2.178 | 0.911 | 2.39x |
| linear_search | 1.639 | 0.445 | 3.68x |
| math_cmp_and_pow_integration_benchmark | 1.427 | 0.494 | 2.89x |
| math_integration_benchmark | 1.256 | 0.508 | 2.48x |
| memory_integration_benchmark | 1.183 | 0.466 | 2.54x |
| operations_with_data_structures_benchmarks | 1.766 | 0.490 | 3.61x |
| pedersen | 0.599 | 0.109 | 5.50x |
| poseidon_integration_benchmark | 0.784 | 0.468 | 1.67x |
| secp_integration_benchmark | 2.169 | 0.621 | 3.49x |
| set_integration_benchmark | 0.752 | 0.169 | 4.45x |
| uint256_integration_benchmark | 2.157 | 1.000 | 2.16x |
| **total** | **25.456** | **9.013** | **2.82x** |

Programs are cairo-vm's `cairo_programs/benchmarks/*.cairo`, compiled with cairo-lang 0.13.5.
Reproduce with `bench/compare.py RUST_CLI _build/default/bin/main.exe progs/*.json --trace`.
