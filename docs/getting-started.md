# Getting started

## Install

### Use the release binaries

Download the archive for your platform and its adjacent SHA-256 file from
[GitHub Releases](https://github.com/teddyjfpender/cairo-vm-ocaml/releases).
On Apple Silicon the 0.2.0 binaries link to Homebrew GMP at
`/opt/homebrew/opt/gmp/lib/libgmp.10.dylib`. Install it with `brew install gmp`.
From the directory containing the downloaded files, run:

```sh
shasum -a 256 -c oxcairo-v0.2.0-macos-arm64.tar.gz.sha256
tar -xzf oxcairo-v0.2.0-macos-arm64.tar.gz
export PATH="$PWD/oxcairo-v0.2.0-macos-arm64:$PATH"
cairo-vm-cli --version
```

The version string identifies OxCairo alongside the Rust CLI version it targets.
Use absolute executable paths when comparing two installations.

### Build from source

PIE archives use zlib. On Linux install the zlib development headers (`zlib1g-dev` on Debian and Ubuntu). On macOS the SDK provides them.

The VM builds with OxCaml, an OCaml compiler with extra optimisations, installed through opam:

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch 5.2.0+ox)
opam install dune zarith yojson
dune build --profile release
```

`opam install .` installs OxCairo's binary as both `cairo-vm-ocaml` and `cairo-vm-cli`, so scripts that
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

## Run a Starknet block from a fresh checkout

Use a checkout of this repository matching your release. From its root, the
following commands run the pinned OS and genesis witness using the packaged CLI.
The checkout supplies both inputs. The first command expands the compiled
program into a temporary directory.

```sh
work=$(mktemp -d)
gzip -dc test/fixtures/programs/starknet-os-training.json.gz > "$work/os.json"
cairo-vm-cli "$work/os.json" --layout all_cairo \
  --os_hints test/fixtures/os/genesis.json --print_output
```

This genesis run emits 16 public field elements. The fixture contains the full
executable program with debug information removed. Repeating this recipe
requires neither Cargo nor a sequencer build. The matching Rust execution
uses the Starknet sequencer's OS hint processor. The general Rust v4 CLI can
execute ordinary compiled programs and replay a recorded OS PIE directly.

| Starting input or desired output | What supplies it |
| --- | --- |
| CairoZero source | `cairo-compile` from cairo-lang produces compiled program JSON. Both CLIs consume that JSON. |
| Cairo assembly and contract classes for the OS | A compatible upstream compiler supplies the OS program and compiled contracts. The checkout includes compiled OS, Virtual OS and aggregator fixtures. |
| Transactions or a block number | The native runner takes a prepared sequencer witness, including the state and execution information required by that block. Producing fresh witnesses in the reference workflow uses the pinned Rust sequencer and Blockifier. |
| A recorded Cairo PIE | The CLI and replay library consume the archive directly. Secure replay uses the supplied memory and execution resources. |
| AIR public and private input | The CLI writes these files, the trace and relocated memory in proof mode. |
| A verified Stwo proof | The repository's workflow builds the OCaml snapshot exporter and the pinned Rust adapter, prover and verifier separately. |

[Compiled program fixtures](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/main/test/fixtures/programs)
· [Reference witness tooling](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/main/bench/reference)
· [Stwo proving workflow](https://github.com/teddyjfpender/cairo-vm-ocaml/tree/main/bench/reference/stwo)

## Proof mode

Proof mode runs a program compiled with `--proof_mode` and produces the inputs a STARK prover
needs:

```sh
cairo-vm-cli program_proof.json --layout starknet_with_keccak --proof_mode \
  --air_public_input public.json --air_private_input private.json \
  --trace_file run.trace --memory_file run.mem
```

`--cairo_pie_output`, `--run_from_cairo_pie`, `--layout dynamic --cairo_layout_params_file FILE`
and `--fill-holes` work as they do in the Rust CLI. To re-execute a Cairo PIE, pass the zip as the
input file:

```sh
cairo-vm-cli os_run.pie.zip --run_from_cairo_pie --layout all_cairo --print_output
```

The PIE's program has no hints, so its recorded memory supplies every hinted value. The run is
bounded by the PIE's step count, and with the default secure run the PIE it would write must
match the input.

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

## Embed a PIE replay

From OCaml, pass the input archive and the desired output paths to the library.

```ocaml
Cairovm.Pie_run.replay_file ~trace:"trace.bin" ~memory:"memory.bin"
  ~output:"validated.zip" "input.zip"
```

The replay uses secure execution and the `all_cairo` layout by default.
Each artifact path is optional. Serialize VM calls within the process because
the felt pool and builtin state are shared.

For a standalone C or Rust process, build the shared library with
`dune build --profile release bindings/c/oxcairo.so`. The
[header](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/bindings/c/oxcairo.h)
declares `oxcairo_replay_v1`. The first call initializes the embedded OCaml
runtime. Make all calls from the same OS thread. The function returns zero on
success and can copy an error message into a caller-owned buffer.

The [in-memory replay proposal](proposals/pie-snapshot/README.md) specifies the planned Rust interface for receiving owned artifacts.

## Reusing a compiled program

A service that launches a fresh native process for each block can pack its compiler JSON once. The packed file holds program words, references, identifiers and hint descriptions. The runner initializes a fresh VM on every invocation.

```sh
cairo-vm-cli os.json --pack_program os.oxcp
cairo-vm-cli os.oxcp --os_hints block.json --layout all_cairo --print_output
```

Keep the compiler JSON for Rust comparisons. Repack after changing the compiled program. The loader checks the format version and table bounds before execution.

## Run successive blocks in one process

The release archive includes `oxcairo-os-worker`. It loads the compiler program once and starts a fresh secure VM for each request. Each request reads the witness from disk. For example, this stream executes two different blocks and then closes the worker.

```sh
printf '%s\n' 'RUN' 'RUN second-block.json' | oxcairo-os-worker os.json first-block.json
```

The worker prints `READY` once. Each `RUN` emits the public output words and a final `DONE` line. A bare `RUN` uses the initial witness. A path after `RUN ` selects another witness, including paths containing spaces. An execution error exits the process. Supply the corresponding compiled program and append `--virtual-os` or `--aggregator` to run those modes.

## Compressed Cairo PIE output

The writer stores ZIP members by default. Add `--pie_compression_level 6` to compress them. Levels 1 through 9 select DEFLATE. Level 0 selects storage. Archive member contents, CRCs and replay semantics are the same across levels. ZIP sizes and compressed bytes depend on the compressor.

The release build can use libdeflate for archive output and OpenSSL for the two public Starknet secp scalar-multiplication syscalls. The portable build uses zlib and Zarith. On macOS with Homebrew the optional build is:

```sh
OXC_LIBDEFLATE="$(brew --prefix libdeflate)" OXC_OPENSSL="$(brew --prefix openssl@3)" \
  dune build --profile release -j2
```

An absolute prefix links that library's static archive. Set either variable to `system` to use the toolchain's header and library search paths. Omit it to select the portable implementation.

## Unpadded proof execution

Add `--disable_trace_padding` to `--proof_mode` to stop after the final proof instruction and use the unpadded builtin allocation rules from cairo-vm 3.2.0. The default proof invocation pads to the Stone layout's resource requirements. The independent Stwo proof and Rust input comparison can be reproduced from [the qualification instructions](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/e559436e2589f1a10ce4fc6b3dac7a1cdbf4379c/bench/reference/stwo/README.md).

For native OS blob data, pass `--os_da_output coefficients.json` with `--os_hints`. The file contains a JSON array of hexadecimal field elements in sequencer order. A calldata run writes JSON `null`. The producer captures the cells used for the KZG commitment. The encrypted fixture check decrypts the resulting state diff and verifies the commitment with the pinned sequencer. [Reproduction](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/e559436e2589f1a10ce4fc6b3dac7a1cdbf4379c/bench/reference/README.md).
