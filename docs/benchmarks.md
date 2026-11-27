# Benchmarks

Detailed measurements, newest first. Each section names the machine, the Rust version
and the method. Raw paired timings live in [`bench/results/`](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/).

## Native Starknet OS on Apple M4 Max

On the saved four-block, 2,048-Invoke workload, both runners executed 13,101,755 Cairo
steps from sequencer block inputs. Each row gives the median wall time for each binary
and the median of three alternating speedup ratios. OCaml revision `5fee19a` ran on
the 36 GB laptop with unrelated builds active.

| Requested result | Rust (s) | OCaml (s) | Paired speedup |
| --- | ---: | ---: | ---: |
| Printed OS output | 2.101 | 0.331 | 6.38× |
| Printed OS output and merged PIE | 8.053 | 0.540 | 14.75× |

Rust uses the sequencer's `run_os_stateless` API at `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`
with cairo-vm 3.2.0. This API constructs an in-memory PIE even when only output is requested.
OCaml reads its compiled OS JSON at startup. Rust embeds the same bytecode. For the archive
row Rust deflates the members and OCaml stores them uncompressed. File sizes and compression
work therefore differ. Every timed pair matched field output and every requested uncompressed
archive member. The measurements include input parsing, execution, finalization and process
startup. Both runs use `all_cairo`.

Reproduce with `bench/compare_native_os.py --ocaml OCAML_CLI --rust OS_REFERENCE --program OS_JSON
--pairs 3 --merge-extra-segments test/fixtures/os/storage-2048.json.gz` using `bench/os_reference.rs`
as the Rust example. [Paired observations](../bench/results/native-os-storage-2048-m4-max.csv).

## Starknet OS PIE replay on Apple M4 Max

Rust cairo-vm v4.0.0 and the OCaml candidate ran sequentially with secure
execution, the `all_cairo` layout and `--print_output`. Each timing is the
median of three wall-clock runs, alternating order within each pair. Full
runs also wrote a trace, relocated memory and a new PIE. All 12 full pairs
matched on stdout, trace, memory and every uncompressed archive member.
The four inputs replay previously executed OS blocks from their recorded
memory. Direct OS execution with transaction and state inputs is a separate
workload. [Raw pairs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bench/results/os-pie-m4-max-rust4.csv)

| Input | Rust exec (s) | OCaml exec (s) | Speedup | Rust full (s) | OCaml full (s) | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SN_PIE_1.zip | 6.145 | 0.520 | 11.83× | 15.422 | 1.122 | 13.75× |
| SN_PIE_2 | 2.952 | 0.278 | 10.61× | 7.714 | 0.573 | 13.46× |
| SN_PIE_3 | 5.515 | 0.507 | 10.88× | 14.746 | 1.087 | 13.57× |
| SN_PIE_4 | 5.635 | 0.460 | 12.24× | 14.315 | 1.096 | 13.06× |

The Rust v3.2.0 comparison used its `mod_builtin` feature to support the OS layout.
All twelve full replay pairs matched on stdout, trace, memory and every PIE member.
Median paired speedups were 11.50×, 13.39×, 12.60× and 12.73× for SN_PIE_1 through
SN_PIE_4. The slowest individual pair was 8.80×.
[Raw v3.2.0 pairs](../bench/results/os-pie-m4-max-rust32.csv)

## Apple M5 Max, Rust cairo-vm v4.0.0 (main at 2b07b77)

After wave 3: a word-at-a-time program loader (load time about halved), cheaper end-of-run
checks (keccak and blake2s 1.2–1.3× faster end to end), trace and memory files written on
background threads, and the hints regrouped by family. Best of three wall-clock runs per
program, `--layout all_cairo --print_output`; every row matched Rust byte for byte. The machine
was busier than for the previous section, so absolute times are higher on both sides; compare
the ratios.

**Execution and printed output** (mean of per-program speedups: 7.4×)

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.540 | 0.085 | 6.38× |
| big_fibonacci | 0.473 | 0.060 | 7.92× |
| blake2s_integration_benchmark | 0.580 | 0.086 | 6.74× |
| compare_arrays_200000 | 0.533 | 0.055 | 9.72× |
| dict_integration_benchmark | 0.474 | 0.101 | 4.70× |
| integration_builtins | 0.760 | 0.072 | 10.49× |
| keccak_integration_benchmark | 0.753 | 0.105 | 7.14× |
| linear_search | 0.506 | 0.061 | 8.28× |
| math_cmp_and_pow_integration_benchmark | 0.576 | 0.080 | 7.18× |
| math_integration_benchmark | 0.525 | 0.074 | 7.05× |
| memory_integration_benchmark | 0.386 | 0.067 | 5.77× |
| operations_with_data_structures_benchmarks | 0.549 | 0.068 | 8.11× |
| pedersen | 0.227 | 0.020 | 11.12× |
| poseidon_integration_benchmark | 0.325 | 0.108 | 3.01× |
| secp_integration_benchmark | 0.695 | 0.123 | 5.66× |
| set_integration_benchmark | 0.300 | 0.030 | 10.06× |
| uint256_integration_benchmark | 0.706 | 0.112 | 6.29× |
| **Total** | **8.905** | **1.307** | **6.81×** |

**Execution, printed output, trace and memory files** (mean: 7.0×)

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 1.014 | 0.155 | 6.56× |
| big_fibonacci | 0.925 | 0.146 | 6.32× |
| blake2s_integration_benchmark | 0.863 | 0.141 | 6.13× |
| compare_arrays_200000 | 1.027 | 0.130 | 7.89× |
| dict_integration_benchmark | 0.760 | 0.156 | 4.89× |
| integration_builtins | 1.138 | 0.130 | 8.77× |
| keccak_integration_benchmark | 1.041 | 0.148 | 7.04× |
| linear_search | 1.033 | 0.122 | 8.48× |
| math_cmp_and_pow_integration_benchmark | 0.926 | 0.136 | 6.83× |
| math_integration_benchmark | 0.835 | 0.118 | 7.07× |
| memory_integration_benchmark | 0.667 | 0.108 | 6.18× |
| operations_with_data_structures_benchmarks | 0.814 | 0.107 | 7.59× |
| pedersen | 0.287 | 0.027 | 10.50× |
| poseidon_integration_benchmark | 0.398 | 0.133 | 2.99× |
| secp_integration_benchmark | 0.899 | 0.153 | 5.89× |
| set_integration_benchmark | 0.365 | 0.041 | 8.80× |
| uint256_integration_benchmark | 1.148 | 0.169 | 6.79× |
| **Total** | **14.139** | **2.119** | **6.67×** |

## Apple M5 Max, Rust cairo-vm v4.0.0 (main at a70bf22)

After the non-moving felt pool with shared field arithmetic (`field.h`), Poseidon round two,
hint hot spots, and proof mode on the native kernel. Best of three wall-clock runs per program,
`--layout all_cairo --print_output`; every row matched Rust byte for byte.

**Execution and printed output** (mean of per-program speedups: 6.7×)

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.367 | 0.061 | 6.03× |
| big_fibonacci | 0.322 | 0.046 | 7.06× |
| blake2s_integration_benchmark | 0.397 | 0.076 | 5.23× |
| compare_arrays_200000 | 0.369 | 0.041 | 9.10× |
| dict_integration_benchmark | 0.321 | 0.073 | 4.38× |
| integration_builtins | 0.509 | 0.061 | 8.29× |
| keccak_integration_benchmark | 0.500 | 0.104 | 4.81× |
| linear_search | 0.388 | 0.040 | 9.61× |
| math_cmp_and_pow_integration_benchmark | 0.388 | 0.060 | 6.52× |
| math_integration_benchmark | 0.356 | 0.053 | 6.67× |
| memory_integration_benchmark | 0.260 | 0.051 | 5.06× |
| operations_with_data_structures_benchmarks | 0.366 | 0.049 | 7.43× |
| pedersen | 0.152 | 0.015 | 9.94× |
| poseidon_integration_benchmark | 0.213 | 0.076 | 2.79× |
| secp_integration_benchmark | 0.462 | 0.091 | 5.10× |
| set_integration_benchmark | 0.203 | 0.022 | 9.09× |
| uint256_integration_benchmark | 0.478 | 0.080 | 5.96× |
| **Total** | **6.049** | **1.000** | **6.05×** |

**Execution, printed output, trace and memory files**

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.715 | 0.130 | 5.50× |
| big_fibonacci | 0.631 | 0.112 | 5.66× |
| blake2s_integration_benchmark | 0.583 | 0.117 | 4.97× |
| compare_arrays_200000 | 0.693 | 0.112 | 6.16× |
| dict_integration_benchmark | 0.512 | 0.115 | 4.47× |
| integration_builtins | 0.783 | 0.114 | 6.85× |
| keccak_integration_benchmark | 0.717 | 0.145 | 4.93× |
| linear_search | 0.723 | 0.109 | 6.63× |
| math_cmp_and_pow_integration_benchmark | 0.640 | 0.109 | 5.90× |
| math_integration_benchmark | 0.574 | 0.100 | 5.74× |
| memory_integration_benchmark | 0.458 | 0.094 | 4.88× |
| operations_with_data_structures_benchmarks | 0.555 | 0.091 | 6.11× |
| pedersen | 0.194 | 0.024 | 8.11× |
| poseidon_integration_benchmark | 0.270 | 0.092 | 2.94× |
| secp_integration_benchmark | 0.612 | 0.119 | 5.12× |
| set_integration_benchmark | 0.250 | 0.035 | 7.11× |
| uint256_integration_benchmark | 0.790 | 0.142 | 5.56× |
| **Total** | **9.702** | **1.761** | **5.51×** |

Proof mode now uses the native kernel too: large proof-mode programs run 1.2–1.9× faster than
before (up to 2.3× faster than Rust, including AIR inputs).

## Apple M5 Max, Rust cairo-vm v4.0.0 (main at de4c6ca)

After the secp field kernel, lazy-reduction Poseidon, the shape-dispatched native kernel and
cheaper hint dispatch. Best of three wall-clock runs per program, `--layout all_cairo
--print_output`. Every row's stdout (and, when traced, trace and memory files) matched
byte for byte.

**Execution and printed output** (mean of per-program speedups: 6.4×)

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.366 | 0.070 | 5.23× |
| big_fibonacci | 0.324 | 0.049 | 6.56× |
| blake2s_integration_benchmark | 0.395 | 0.091 | 4.32× |
| compare_arrays_200000 | 0.388 | 0.040 | 9.62× |
| dict_integration_benchmark | 0.318 | 0.074 | 4.33× |
| integration_builtins | 0.511 | 0.063 | 8.10× |
| keccak_integration_benchmark | 0.505 | 0.119 | 4.24× |
| linear_search | 0.374 | 0.041 | 9.24× |
| math_cmp_and_pow_integration_benchmark | 0.387 | 0.063 | 6.13× |
| math_integration_benchmark | 0.351 | 0.055 | 6.41× |
| memory_integration_benchmark | 0.261 | 0.051 | 5.09× |
| operations_with_data_structures_benchmarks | 0.366 | 0.051 | 7.12× |
| pedersen | 0.155 | 0.014 | 11.08× |
| poseidon_integration_benchmark | 0.215 | 0.091 | 2.35× |
| secp_integration_benchmark | 0.461 | 0.102 | 4.50× |
| set_integration_benchmark | 0.203 | 0.024 | 8.52× |
| uint256_integration_benchmark | 0.480 | 0.083 | 5.76× |
| **Total** | **6.060** | **1.082** | **5.60×** |

**Execution, printed output, trace and memory files**

| Program | Rust (s) | OCaml (s) | Speedup |
| --- | ---: | ---: | ---: |
| big_factorial | 0.689 | 0.144 | 4.77× |
| big_fibonacci | 0.616 | 0.119 | 5.16× |
| blake2s_integration_benchmark | 0.571 | 0.128 | 4.46× |
| compare_arrays_200000 | 0.676 | 0.101 | 6.68× |
| dict_integration_benchmark | 0.501 | 0.112 | 4.48× |
| integration_builtins | 0.757 | 0.117 | 6.48× |
| keccak_integration_benchmark | 0.695 | 0.155 | 4.47× |
| linear_search | 0.695 | 0.105 | 6.60× |
| math_cmp_and_pow_integration_benchmark | 0.618 | 0.113 | 5.45× |
| math_integration_benchmark | 0.556 | 0.108 | 5.14× |
| memory_integration_benchmark | 0.448 | 0.094 | 4.79× |
| operations_with_data_structures_benchmarks | 0.545 | 0.091 | 6.01× |
| pedersen | 0.193 | 0.026 | 7.28× |
| poseidon_integration_benchmark | 0.266 | 0.105 | 2.53× |
| secp_integration_benchmark | 0.605 | 0.132 | 4.59× |
| set_integration_benchmark | 0.248 | 0.036 | 6.85× |
| uint256_integration_benchmark | 0.769 | 0.144 | 5.35× |
| **Total** | **9.448** | **1.831** | **5.16×** |

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

Large traced runs write a lot of data: big_fibonacci writes 688 MB of trace and memory. The
earlier claim here that ~7 GB/s was the machine's limit was wrong. The internal SSD sustains about
13–14 GB/s with large `write(2)` chunks or `F_NOCACHE` (Apple's rated figure is 14.5 GB/s), and no
write technique beats that. Lower measurements came from other processes and Spotlight writing at
the same time, and from relocating and writing in turn instead of overlapping them. In proof mode,
I/O is under 10% of the time; most of it is building the AIR private input and the end-of-run
checks.

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
