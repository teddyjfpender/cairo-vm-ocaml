# From an OS witness to a replayable PIE

A compiled OS program contains instructions. Its witness supplies block-specific data that OS hints read while those instructions run. A Cairo PIE records the completed execution so another VM can check it later. Here you will generate one from the Apollo genesis fixture and verify its memory against an independent Rust result.

## Prepare the two inputs

From the root of an OxCairo v0.3.0 source checkout, activate the OxCaml switch used to build the project. This recipe uses jq, gzip and unzip. The fixture manifest pins the genesis block hash. The witness changes below select the matching OS version and full-output mode used for this reference case.

```sh
work=$(mktemp -d)
fixtures=test/fixtures/programs/apollo-0.20.0-rc.1
gzip -dc "$fixtures/os.json.gz" > "$work/os.json"
jq --arg hash "$(jq -r .genesis.block_hash "$fixtures/cases.json")" '
  .os_input.os_block_inputs[0] |= (
    .block_info.starknet_version = "0.14.4" |
    .new_block_hash = $hash | .starknet_version_override = null
  ) | .os_hints_config.full_output = true
' test/fixtures/os/genesis.json > "$work/genesis.json"
mkdir -p pie_example
```

## Build and run a fresh VM

Save this stanza as `pie_example/dune`.

```lisp
(executable
 (name make_pie)
 (libraries cairo-vm-ocaml))
```

Save the following as `pie_example/make_pie.ml`. The type annotations show which values you could keep between requests. A `Program_image.t` holds prepared program data. Each witness gets its own `Runner.t`, with fresh registers, memory, builtin state and trace.

```ocaml
open Cairovm

let generate (program : Program.t) (image : Program_image.t) witness_path output =
  Felt.with_temporary_slots (fun () ->
    let config = { Cairo_run.default_config with layout = "all_cairo"; trace = true } in
    let input : Os_hints.input = Os_hints.read_witness witness_path in
    let runner : Runner.t =
      Os_hints.initialize_input ~image ~record_trace:true ~proof:false input config program
    in
    Runner.run_until_end ~max_steps:100_000_000 runner;
    Finalize.end_run runner ~secure:true ~allow_missing:false;
    Pie.write ~profile:Pie_zip.Fast ~compression_level:0
      ~merge_extra_segments:false ~main:(Runner.entry_pc config program)
      ~secure:true runner output)

let () =
  let program = Program.load_file Sys.argv.(1) in
  let image = Program_image.prepare program in
  generate program image Sys.argv.(2) Sys.argv.(3)
```

`run_until_end` advances the VM until its return address or step limit. Finalization verifies deductions and builtin stop pointers and performs the secure-run checks. The writer then encodes the finalized segments, memory and resources. Here it stores the ZIP members without compression. The scope around the job lets the runtime reclaim temporary field-element slots. Serialize VM calls when using the OCaml library in one process. For deadlines, typed refusals, memory limits and durable publication, use the [OS-host process interface](os-host.md).

```sh
dune exec --profile release ./pie_example/make_pie.exe -- \
  "$work/os.json" "$work/genesis.json" "$work/genesis.zip"
unzip -p "$work/genesis.zip" execution_resources.json | jq '{n_steps, n_memory_holes}'
unzip -p "$work/genesis.zip" memory.bin > "$work/memory.bin"
(cd "$work" && shasum -a 256 memory.bin)
jq -r '.genesis.execution.pie["memory.bin"]' "$fixtures/cases.json"
```

The fixture takes 5,142 steps and reports 58 memory holes. The two memory digests should both be `99bfd976086c845ace970e064b0fcbcd16cd2c16772f325c0bbdd2ebe757845a`. This comparison checks every encoded memory record. For a complete PIE comparison, also compare the four JSON members: `version.json`, `metadata.json`, `additional_data.json` and `execution_resources.json`. Archive-level equality also requires matching compression, headers and segment layout.

## Replay the result

The recorded memory supplies the values originally produced by hints. Secure replay uses the recorded step budget, checks that execution reaches the expected endpoint and verifies the resulting PIE state. Run the following from the same checkout.

```sh
dune exec --profile release ./bin/main.exe -- "$work/genesis.zip" \
  --run_from_cairo_pie --layout all_cairo --trace_file "$work/replay.trace"
```

The corresponding OCaml call is:

```ocaml
let replay input trace_path =
  Cairovm.Pie_run.replay_file ~trace:trace_path input
```

A PIE records a computation. Generating a cryptographic proof also requires the proof-mode program and an external prover. [Runs, relocation and proofs](learn/runs-and-proofs.md)
