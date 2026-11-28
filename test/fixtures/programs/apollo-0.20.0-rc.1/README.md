# Apollo 0.20.0-rc.1

These fixtures use sequencer revision `1860b9850b5c51858c50c0f5038933e49f932eef`, cairo-vm 3.2.0, Cairo 0 compiler 0.14.3a3 and cairo-lang-casm 2.19.5. Select the main OS, virtual OS or aggregator explicitly by decompressing the corresponding JSON program. Select the matching `.proof.json.gz` when producing proof artifacts. The surrounding directory retains the existing `ffdf1f9e` fixtures. [Sequencer source and build script](https://github.com/starkware-libs/sequencer/tree/1860b9850b5c51858c50c0f5038933e49f932eef/crates/apollo_starknet_os_program)

```sh
fixtures=test/fixtures/programs/apollo-0.20.0-rc.1
gzip -dc "$fixtures/os.json.gz" > os.json
cairo-vm-cli os.json --layout all_cairo --os_hints WITNESS.json --cairo_pie_output result.zip
python3 "$fixtures/check.py" --binary "$(command -v cairo-vm-cli)"
```

`manifest.json` records each upstream program hash, bytecode word count, distinct hint count, compiler output SHA-256 and compact JSON SHA-256. Source filenames and the temporary virtual source directory can change full debug-file hashes between builds. To regenerate portable bytes, preserve compiler key order, set `debug_info` to null and encode with Python `json.dumps(program, separators=(",", ":")).encode()`. The hint inventory digest uses the same encoding on the sorted set of hint source strings.

## Independent reference

In a clean checkout of the pinned sequencer, activate Cairo 0.14.3a3 and place this repository's `bench/{os_reference,virtual_os_reference,aggregator_reference}.rs` and `bench/reference/{header_hash,os_traced}.rs` in `crates/starknet_os/examples/`. Run the following from that checkout.

```sh
cargo build --locked --release -j1 -p starknet_os --features deserialize \
  --example os_reference --example virtual_os_reference --example aggregator_reference \
  --example os_traced --example header_hash
python3 "$FIXTURES/check.py" --reference-dir "$PWD/target/release/examples" --stock-cli "$CAIRO_VM_320"
```

The crate produces `starknet_os_bytes`, `virtual_os_bytes` and `starknet_aggregator_bytes` in its Cargo build output. Proof programs are compiled separately with `cairo-compile MAIN --proof_mode --no_debug_info --cairo_path CAIRO_ROOT`. The main file is `starkware/starknet/core/os/os.cairo` or `starkware/starknet/core/aggregator/main.cairo` below the upstream Cairo source root. For the virtual OS, copy that root and replace each original Cairo file with its `__virtual.cairo` counterpart, following the upstream build script. The ordinary bytecode lacks proof start and end labels.

## Coverage

Five main OS cases cover genesis, an explicit newer on-chain version override, an account, deprecated calls and a reverted invoke. Two virtual OS witnesses exercise execution info and a 16-call multicall. The aggregator consumes the full genesis output with the pinned OS program hash and calldata availability. These are public synthetic flow fixtures. For the older protocol, the fixture builder selects Starknet 0.14.4 and uses the header hashes recorded in `cases.json`. The override retains the original fixture hash, as Rust hashes the explicitly supplied version string. For the remaining inputs, the Rust `header_hash os|virtual_os WITNESS.json` example independently calculated these hashes from the fixture's trie commitments using the pinned Starknet API. The single-task bootloader input is `[1, 2 + output_length, os_program_hash, ...output]` using the full genesis words yielded by `os_reference`.

For every witness, the checker compares stdout, relocated trace and memory, all five uncompressed PIE members, proof trace, proof memory, and both AIR inputs. AIR JSON is hashed after canonical parsing. AIR private trace and memory paths are validated against the produced files before normalization. The pinned tracer executes the stock hint processors. Actual proof generation and verification are separate operations.

The account fixture also checks that enabling Rust's optional gas diagnostics rejects a later-protocol prediction. Two additional later-protocol witnesses, a virtual L1 message and a nested revert, failed the historical reference's syscall gas assertion when their header versions were translated. They are outside the successful historical corpus.

The separate `standard-hints.cairo` fixture compiles public Cairo standard-library allocation, copy, fill, division and comparison routines. The checker recovers executed program counters from the relocated trace and verifies that all 14 distinct hint bodies execute. Recompile with `cairo-compile standard-hints.cairo --no_debug_info --output standard-hints.json` and compare `cairo-vm-cli standard-hints.json --layout all_cairo --trace_file trace.bin --memory_file memory.bin` using stock cairo-vm 3.2.0.
