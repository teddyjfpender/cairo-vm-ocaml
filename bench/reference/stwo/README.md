# Proving a native Cairo execution with Stwo

The native snapshot exporter records the VM's unrelocated memory, trace, builtin indices and public offsets. The adapter uses the upstream builtin padding, relocation, memory builder and opcode classifier. It sorts the public-address vector in both runs because the underlying segment map has no iteration order. All other adapted fields are compared directly.

The pinned Stwo Cairo revision is `9b6be2710e4d7124bc93fe80a5af36556d42ed29` in `starkware-libs/stwo-cairo`. Use its `stwo_cairo_prover` workspace and its pinned Rust nightly. Its lockfile resolves Stwo to `489a0f3ee44a59e03944ad9aa4f3e5a91a3d3f08` and cairo-vm to 3.2.0. Copy `ocaml_snapshot.rs` into `crates/dev_utils/src/bin/` in that workspace. Build in a private target directory.

```sh
cargo build --locked --release -j1 --bin ocaml_snapshot --bin prove --bin verify
```

In OxCairo, build `bench/stwo_snapshot.exe` with Dune's release profile. For an upstream compiled test program, run the following with the three Rust executables on PATH. Supplying the compiled program to the adapter requests an independent Rust execution and field-by-field comparison before proving.

```sh
_build/default/bench/stwo_snapshot.exe compiled.json snapshot.json
ocaml_snapshot snapshot.json prover-input.json compiled.json
prove --prover_input_path prover-input.json --proof_path proof.json --params_json fixture-params.json
verify --proof_path proof.json
```

For the OS proof, use the sequencer and OS program pinned in the parent directory. Produce the genesis PIE from the versioned native witness, then run that PIE as a task inside `cairo-program-runner-lib` 1.3.1's `simple_bootloader_compiled.json`. The task file contains `{"tasks":[{"type":"CairoPiePath","path":"genesis.zip","program_hash_function":"blake"}],"single_page":false}`. Use an absolute archive path when running the two VMs from different directories.

```sh
cairo-vm-cli os.json --layout all_cairo --os_hints test/fixtures/os/genesis.json \
  --cairo_pie_output genesis.zip --merge_extra_segments
_build/default/bench/stwo_snapshot.exe simple_bootloader_compiled.json snapshot.json --bootloader task.json
ocaml_snapshot snapshot.json prover-input.json
```

Copy `boot_snapshot.rs` into the pinned sequencer's `crates/starknet_os/examples/` and build it with the same dependencies as `bench/bootloader_reference.rs`. This obtains an independent Rust snapshot and checks the entire adapted OS prover input.

```sh
boot_snapshot simple_bootloader_compiled.json task.json rust-snapshot.json
ocaml_snapshot rust-snapshot.json rust-input.json
cmp prover-input.json rust-input.json
RAYON_NUM_THREADS=1 prove --prover_input_path prover-input.json --proof_path proof.json --params_json os-params.json
verify --proof_path proof.json
```

The saved receipts give the input and proof digests, proof lengths and sampled peak RSS. The proofs used Blake2s, the upstream canonical-small preprocessed trace, 70 FRI queries and 26 proof-of-work bits. The explicit lifting sizes bound the prover's twiddle allocation. Canonical-small excludes the EC-op builtin. The all-builtins fixture passed adapted-input equality and is outside the verified-proof table. This qualification covers the recorded upstream fixtures and four sequencer-generated OS tasks. The additional account, reverted invoke and multiblock executions also produced identical complete prover inputs from the two VMs. Use the same OS proof parameters for those tasks.

The upstream `all_opcode_components` fixture uses a valid cairo-vm 3.2 generic conditional jump. Add `--legacy` to the snapshot command for this fixture. The native CLI exposes the same compatibility setting as `--allow_legacy_instructions`. The default decoder follows v4.0.0. All 1,495 steps produced the same adapted input as Rust, and the independent verifier accepted its proof with the fixture parameters.

## Direct proof-mode compilation of the OS

The stock sequencer embeds the execution-mode compiler image. For a direct proof, compile the pinned OS source with its Cairo 0 compiler and proof entry point. The compiler embeds source paths in its debug information. Run the following with the pinned sequencer's Cairo source directory in `CAIRO_ROOT`.

```sh
cairo-compile "$CAIRO_ROOT/starkware/starknet/core/os/os.cairo" --proof_mode \
  --debug_info_with_source --cairo_path "$CAIRO_ROOT" --output os-proof.json
```

Install `raw_os_snapshot.rs` and `snapshot_common.rs` next to each other in the sequencer's `starknet_os/examples/` directory. Build the example with the `deserialize,testing` features. The bootloader snapshot example uses the same serializer. Run the four versioned witnesses under both layouts with the release exporter and the independent reference.

```sh
python3 bench/reference/stwo/check_raw_os.py os-proof.json \
  _build/default/bench/stwo_snapshot.exe /path/to/raw_os_snapshot /path/to/ocaml_snapshot
```

Genesis and the multiblock witness execute directly in `all_cairo_stwo`. Both complete adapted inputs matched Rust and upstream Stwo verified both proofs with `os-params.json`. In `all_cairo`, all four raw state snapshots matched across trace rows, memory cells, builtin segments, and output page assignments. The upstream Stwo adapter rejects this layout's ECDSA builtin. In `all_cairo_stwo`, both VMs reject the direct account and reverted-transaction witnesses when the OS logger reads a missing builtin pointer. Their bootloader proofs above remain independently reproducible.

The direct aggregator's four-block storage and five-block syscall witnesses also produced matching adapted inputs. The pinned prover rejected both while converting a field value to a 128-bit integer. These two are input-equality checks only.
