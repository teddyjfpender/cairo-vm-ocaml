# Memory-bounded sequencer reference

The release baseline in `../os_reference.rs` calls the stock sequencer API. That API builds a relocated memory image and a Cairo PIE even when the caller requests only public output. The diagnostic example in this directory executes the same OS initialization, CPU, hints, end-of-run checks, auto-deductions and return-value reads. Its output mode stops there. Its archive mode streams assigned cells through the original PIE encoder in batches of 16,384, preserving the segment merge map and serialization order.

Use sequencer commit `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45` with cairo-vm 3.2.0. Work in a separate checkout. Copy `os_verified.rs` to `crates/starknet_os/examples/` and add `oxcairo_stream = []` under `[features]` in that crate's Cargo.toml. For public output alone, build with the original VM dependency.

```sh
cargo build --locked --release -j2 -p starknet_os --example os_verified --features deserialize
target/release/examples/os_verified INPUT.json
```

For archives, unpack a fresh copy of the cairo-vm 3.2.0 source to a private directory and apply `stream-cairo-pie-3.2.patch` there with `patch -p1`. Replace the example path in the Cargo override with its absolute path. Cargo updates the private checkout's lockfile for the path override.

```sh
cargo build --release -j2 -p starknet_os --example os_verified \
  --features deserialize,oxcairo_stream \
  --config 'patch.crates-io.cairo-vm.path="/absolute/path/to/cairo-vm-3.2.0"'
target/release/examples/os_verified INPUT.json merged-pie.zip
```

At 4,096 repeated storage invokes and 32 mixed syscall repetitions, the streamed archive matched the stock writer on all five decompressed members. At 8,192 invokes and 64 repetitions, the stock process exceeded the local 4 GiB RSS allowance. The saved digests for those two larger cases consequently use the streamed Rust reference. Archive compressed bytes and ZIP metadata are outside the comparison.

## Deployment and L1-handler witnesses

The two largest deployment fixtures each contain four consecutive blocks, one Sierra declaration, 2,048 fresh contract deployments, 2,048 contract calls that write distinct storage keys, and 2,048 successful L1 handlers. The upstream Blockifier and committer produced the execution and Patricia witnesses. Calldata and blob availability use separate OS inputs. The public output is hashed as a sequence of canonical little-endian 32-byte field elements. The archive receipts cover all five uncompressed members.

To regenerate the transactions, append the contents of `deployment_witness.rs` to `crates/starknet_os_flow_tests/src/tests.rs` in the pinned checkout. In the test manager, serialize `self.os_hints` with `serde_json::to_writer` after the committer populates the block inputs and immediately before OS execution. Run `tests::test_oxcairo_wide_deploy_and_l1` with `OXCAIRO_DEPLOYS=2048`. Set `OXCAIRO_BLOB=1` for the blob case. Convert the chain name in `os_hints_config.chain_info.chain_id` to its ASCII bytes encoded as a hexadecimal felt before passing the witness to either VM.

The stock API exceeded the 3.3 GiB process allowance on the two 6,145-transaction inputs. Their public outputs and archive hashes use the memory-bounded Rust reference above. Smaller cases through 3,073 transactions also have stock API timings. Empty RSS cells in the timing file mean the child exited between samples.


## Compiler input identity

Pass the sequencer build's `apollo_starknet_os_program-*/out/starknet_os_bytes` file to `bench/compare_native_os.py --program`. The harness maps the independent Rust executable and checks that the complete compiler file occurs byte-for-byte in its image before starting any timings. Both VMs then use those bytes. To test a packed or debug-stripped input, supply the verified compiler output as usual and also pass `--prepared-program ALTERNATIVE`. The resulting rows are labelled and carry both SHA-256 digests.

For persistent production-runner comparisons, build `os_verified.rs` for the main OS or `related_workers.rs` for the virtual OS and aggregator as a sequencer example. The main OS diagnostic omits materialization of unrequested artifacts. The related workers call the stock public sequencer APIs. Each timed command reads the entire witness, creates a new VM and checks the public words. Both processes warm up once per input. The compiler program supplied to the OCaml worker must be present byte-for-byte in the reference executable.

```sh
python3 bench/compare_native_os_workers.py --kind virtual-os --pairs 7 \
  --rust /path/to/oxcairo_related_workers --ocaml _build/default/bench/native_os_worker.exe \
  --program /path/to/virtual_os_bytes test/fixtures/os/virtual-multicall-64.json.gz
```

The mixed-revert generator runs successful writes between deliberately reverted transactions against predeployed Cairo 0 and Cairo 1 contracts. Append `reverted_witness.rs` to the pinned flow tests and run `test_oxcairo_mixed_reverts` with `OXCAIRO_ROUNDS=3072`. The complete test fixture contains 9,216 transactions in four blocks. Its five member digests come from the independent streaming Rust reference.

The four encrypted witnesses use the publicly specified test private keys from the sequencer's flow suite. Copy `encrypted_os.rs` to the sequencer's `starknet_os/examples` directory and build the example with `cargo build -p starknet_os --example encrypted_os --features deserialize,testing`. The checker runs the stock API and compares decoded common output and plaintext state updates twice per fixture. For committed outputs it also uses the sequencer's KZG segment validator.

```sh
python3 test/fixtures/os/encrypted/check.py /path/to/cairo-vm-cli /path/to/encrypted_os /path/to/starknet_os_bytes
```

## STRK transfers

Append `erc20_witness.rs` to the pinned flow tests and run `test_oxcairo_erc20_transfers` with `OXCAIRO_TRANSFERS` and `OXCAIRO_RECIPIENTS` set to the transfer and recipient counts. The funded account makes an ordinary call to the STRK token contract for every transfer. The upstream test builder checks the expected token event and splits the transactions into four consecutive blocks. Capture and normalize the witness as described above for deployments.

Two committed witnesses cover 8,192 transfers to 16 recipients and 4,096 transfers to 4,096 recipients. The complete OS executions took 64,202,029 and 42,013,031 Cairo steps. Each fixture includes the sequencer's transaction execution records and state witnesses. The offline checker compares its five decompressed PIE members and digest of every public output word against the streaming Rust reference.

The CASM arithmetic vectors call the same `execute_core_hint_base` interpreter used by the pinned OS. Copy `casm_hint_vectors.rs` to `starknet_os/examples/` and run `cargo run -p starknet_os --example casm_hint_vectors --features deserialize,testing` to reproduce `test/casm_hints/vectors.json`. The OCaml tests replay each serialized hint sequence and compare every resulting stack and range-check word.

For steady-state timings on a profile-guided build, pass `--worker-output PATH` to `scripts/build_pgo.py`. The CLI and worker then link the native kernel built from the same training profile. Both workers reread the witness and initialize a new VM on every request.

The same related runner accepts a single cold request and can write a PIE. The native comparison harness can time public output alone, PIE output alone, or both. It checks every public word on every pair and compares the decompressed archive members when requested. An optional RSS limit samples each benchmark child and terminates that child when the limit is exceeded.

```sh
python3 bench/compare_native_os.py --kind virtual-os --mode both --pairs 5 \
  --max-rss-mib 2048 --rust /path/to/related_workers --ocaml /path/to/cairo-vm-cli \
  --program /path/to/virtual_os_bytes test/fixtures/os/virtual-multicall-64.json.gz
```
