# cairo-vm-ocaml

A fast CairoZero virtual machine written in OCaml, built with [OxCaml](https://oxcaml.org/).
The native runner produced byte-identical trace and memory files to upstream
Rust cairo-vm 3.2.0 on all 17 CairoZero benchmark programs below.

## Results

### Linux x86-64, Rust 3.2.0 and the installed OCaml CLI

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
disabled. Raw pairs: [execution](bench/results/rust-3.2.0-run.csv) and
[trace and memory](bench/results/rust-3.2.0-traced.csv).

The targeted [Keccak byte-prefix workload](bench/keccak_byte_prefixes.cairo)
queries 4,096 increasing, non-word-aligned lengths from one immutable Cairo
array. Eight alternating traced pairs measured 0.825 s for Rust and
0.038 s for OCaml (21.9×). A separate paired comparison against the preceding
OCaml revision measured 1.359 s and 0.024 s (56.7×). These ratios apply
to repeated prefixes. [Rust pairs](bench/results/keccak-byte-prefixes-vs-rust.csv)
and [parent pairs](bench/results/keccak-byte-prefixes-vs-parent.csv).

### Earlier Apple M5 Max baseline

Apple M5 Max, best of 3 wall-clock runs, `--layout all_cairo --print_output --trace_file … --memory_file …`
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

## Why it is fast

- **One immediate int per value.** Small felts (|v| < 2^59), relocatables and empty cells are tagged
  OCaml ints. Big felts are interned in an append-only pool of canonical limbs, so equality, pointer
  arithmetic and most additions never touch 256-bit arithmetic or allocate.
- **Off-heap memory.** Segments and the trace are `calloc`-backed Bigarrays: the GC never scans
  them, there is no write barrier, and untouched capacity costs nothing.
- **Fast interpreter loop.** Registers live in locals; decoded instructions are cached per pc with a
  hint flag bit. The common case (operands present, `[ap]` freshly written) runs without leaving
  the loop. Anything unusual falls back, before any mutation, to a generic step implementing the
  full operand-deduction rules.
- **C kernel for the field.** Montgomery arithmetic specialised to the Stark prime, Pedersen with
  precomputed 4-bit window tables, Poseidon (Hades), Keccak-f, EC op, and GMP inversion.
- **C binary writers** for the trace and memory files.

## Usage

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox)
opam install dune zarith yojson
dune build --profile release
_build/default/bin/main.exe program.json --layout all_cairo --print_output \
  --trace_file out.trace --memory_file out.mem --stats
```

Installing the package with `opam install .` installs both `cairo-vm-ocaml`
and `cairo-vm-cli` in the switch. Existing execution scripts can select the
OCaml implementation through `PATH`. If Rust is already installed, keep its
executable in a separate directory.

The native command accepts the Rust execution flags, including
`--fill-holes true|false` for deducible builtin output cells. To use Rust for
proof mode, AIR JSON, Cairo PIE creation and replay, or dynamic layouts, set
`CAIRO_VM_RUST_CLI` to the separate upstream executable's absolute path.
The CLI forwards those commands with their original arguments. A native VM
execution error also retries through that executable before emitting output,
except when the OCaml-only `--stats` flag is active.

For example, an existing proof-mode script can keep calling `cairo-vm-cli`
after activating the OCaml switch:

```sh
export CAIRO_VM_RUST_CLI=/path/to/rust/cairo-vm-cli
cairo-vm-cli proof-program.json --layout all_cairo --proof_mode \
  --air_public_input public.json --air_private_input private.json \
  --trace_file run.trace --memory_file run.mem
```

For OCaml applications, add `(libraries cairo-vm-ocaml)` to the Dune stanza:

```ocaml
open Cairovm

let execute file =
  let config = { Cairo_run.default_config with layout = "all_cairo"; trace = true } in
  let result = Cairo_run.run_file ~config ~fill_holes:true file in
  Runner.iter_output_lines result print_endline;
  Runner.write_trace result "out.trace";
  Runner.write_memory result "out.mem"
```

The embedded API uses the native runner. Its felt storage is process-global
and retains allocated values between calls. Use separate processes for
concurrent jobs or to reclaim the entire pool after a job.

To compare release binaries on your own compiled workload and check stdout
and both binary artifacts on every pair, run:

```sh
python bench/compare_cli.py --trace /path/to/rust/cairo-vm-cli /path/to/ocaml/cairo-vm-cli programs/*.json
```

Run the compatibility checks with `cairo-compile` 0.13.5 on `PATH`:

```sh
dune runtest --profile release
python test/cli/compare.py /path/to/rust/cairo-vm-cli /path/to/ocaml/cairo-vm-cli
```

## Scope and limitations

- Native execution supports non-proof mode. Proof mode requires the configured Rust CLI.
- Builtins: output, pedersen, range_check, range_check96, bitwise, ec_op, keccak, poseidon.
  ecdsa, add_mod and mul_mod are rejected explicitly, as are the Blake and QM31 opcode extensions.
- The native hint processor recognizes the 86 cairo-lang hints used by the benchmark suite
  and the Uint256 multiply/divide-with-remainder hint. It matches exact code strings, as cairo-vm does.
- Big-felt intermediates are kept in an append-only pool for the life of the process.
- Passing differential tests is evidence of compatibility, not a proof of refinement.

## License

Apache-2.0. Hash constants are generated by `scripts/gen_constants.py` from the
`starknet-curve` and `lambdaworks-crypto` crates.
