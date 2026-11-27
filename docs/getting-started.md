# Getting started

## Install

The VM builds with OxCaml, an OCaml compiler with extra optimisations, installed through opam:

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox)
opam install dune zarith yojson
dune build --profile release
```

`opam install .` installs the binary as both `cairo-vm-ocaml` and `cairo-vm-cli`, so scripts that
call `cairo-vm-cli` pick up this VM through `PATH`. Keep a Rust `cairo-vm-cli` in a separate
directory if you want both.

## Compile a program

The VM runs compiled CairoZero programs (JSON). Compile one with cairo-lang's `cairo-compile`:

```sh
cairo-compile program.cairo --output program.json
cairo-compile program.cairo --output program_proof.json --proof_mode   # for proof mode
```

## Run it

```sh
cairo-vm-cli program.json --layout all_cairo --print_output \
  --trace_file out.trace --memory_file out.mem
```

| Flag | Effect |
| --- | --- |
| `--layout NAME` | builtin layout (`plain`, `small`, `all_cairo`, `starknet_with_keccak`, `dynamic`, ...) |
| `--print_output` | print the output builtin's values |
| `--trace_file F` / `--memory_file F` | write the binary trace and relocated memory |
| `--proof_mode` | run as a proof-mode program (see below) |
| `--stats` | OCaml-only: print steps, timing and steps per second |

## Proof mode

Proof mode runs a program compiled with `--proof_mode` and produces the inputs a STARK prover
needs:

```sh
cairo-vm-cli program_proof.json --layout starknet_with_keccak --proof_mode \
  --air_public_input public.json --air_private_input private.json \
  --trace_file run.trace --memory_file run.mem
```

`--cairo_pie_output`, `--layout dynamic --cairo_layout_params_file FILE` and `--fill-holes`
work as they do in the Rust CLI.

## Use it as a library

Add `(libraries cairo-vm-ocaml)` to a dune stanza:

```ocaml
open Cairovm

let execute file =
  let config = { Cairo_run.default_config with layout = "all_cairo"; trace = true } in
  let result = Cairo_run.run_file ~config ~fill_holes:true file in
  Artifacts.iter_output_lines result print_endline;
  Artifacts.write_trace result "out.trace";
  Artifacts.write_memory result "out.mem"
```

The pool that stores large field elements is process-global. Run one VM at a time per process.

## Forwarding to a Rust CLI (optional)

If `CAIRO_VM_RUST_CLI` names an upstream `cairo-vm-cli`, any invocation the OCaml CLI can't run
natively is forwarded with its original arguments. Native execution errors are also retried
there. Forwarding is off unless you set the variable, and all parity results are measured with
it off.

## Exercises

1. Build the VM and run a benchmark with `--stats`. How many steps does it execute, and at what
   rate?
2. Run the same program with and without `--trace_file`/`--memory_file`. How much of the time
   goes to writing the files?

<details markdown>
<summary>Hints</summary>

1. Programs from the upstream repository live in `cairo_programs/benchmarks/`. `--stats` prints
   `steps=...` and `run=...s (... Msteps/s)` on stderr.
2. Use `/usr/bin/time -p`. On large CPU-bound programs most of the extra time is the filesystem
   absorbing hundreds of megabytes; see [Benchmarks](benchmarks.md).

</details>
