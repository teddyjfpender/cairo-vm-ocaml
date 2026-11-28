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
