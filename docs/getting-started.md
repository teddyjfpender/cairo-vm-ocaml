# 🚀 Getting started

## Install

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox)
opam install dune zarith yojson
dune build --profile release
```

`opam install .` installs both `cairo-vm-ocaml` and `cairo-vm-cli` in the switch, so existing
scripts pick up the OCaml VM through `PATH`. Keep a Rust `cairo-vm-cli` in a separate directory.

## Run a program

The CLI takes the same flags as the Rust `cairo-vm-cli`:

```sh
cairo-vm-cli program.json --layout all_cairo --print_output \
  --trace_file out.trace --memory_file out.mem
```

Add `--stats` to print the step count and speed.

## Proof mode

```sh
cairo-vm-cli program.json --layout starknet_with_keccak --proof_mode \
  --air_public_input public.json --air_private_input private.json \
  --trace_file run.trace --memory_file run.mem
```

`--cairo_pie_output`, `--layout dynamic --cairo_layout_params_file` and `--fill-holes` are
supported as well.

## Use it as a library

Add `(libraries cairo-vm-ocaml)` to your dune stanza:

```ocaml
open Cairovm

let execute file =
  let config = { Cairo_run.default_config with layout = "all_cairo"; trace = true } in
  let result = Cairo_run.run_file ~config ~fill_holes:true file in
  Artifacts.iter_output_lines result print_endline;
  Artifacts.write_trace result "out.trace";
  Artifacts.write_memory result "out.mem"
```

The felt pool is process-global, so run one VM per process at a time.

## Optional: forward to a Rust CLI

Set `CAIRO_VM_RUST_CLI` to the absolute path of an upstream executable, and the OCaml CLI
forwards any invocation it can't run natively (and retries native errors there) with the
original arguments. This is off by default. Parity results are always measured with
forwarding disabled.
