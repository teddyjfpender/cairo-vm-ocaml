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

## Verified Stwo proofs

The upstream Stwo verifier accepted three freshly produced proofs. Genesis uses the direct proof-mode OS. Virtual execution info and the single-block aggregator run their complete execution PIEs as tasks in `cairo-program-runner-lib` 1.3.1's simple bootloader. The OCaml and independent Rust snapshots produced identical adapted prover inputs in all three successful runs. [Per-proof digests and archive identity](stwo-verified.json) · [Pinned prover, verifier, adapters and parameters](../../../../bench/reference/stwo/README.md)

Use the repository's `bench/reference/stwo/os-params.json` for all three. The direct virtual execution-info run under `all_cairo_stwo` fails in both VMs on the missing builtin pointer at address `1:632`. The direct aggregator produced identical Rust and OCaml adapted inputs, then the prover rejected a field value during conversion to u128. These outcomes refer to the direct Stwo cases. Both families pass the ordinary `all_cairo` proof-artifact comparisons above.

With the adapter and binaries from the linked setup on PATH, run the following from the OxCairo checkout. Set `BOOTLOADER` to the absolute path of `simple_bootloader_compiled.json`.

```sh
python3 "$fixtures/check.py" --prepare historical-inputs
cd historical-inputs
stwo_snapshot os.proof.json genesis.snapshot --os genesis.json
ocaml_snapshot genesis.snapshot genesis.input
RAYON_NUM_THREADS=1 prove --prover_input_path genesis.input --proof_path genesis.proof.json --params_json ../bench/reference/stwo/os-params.json
verify --proof_path genesis.proof.json

for family in virtual_os aggregator; do
  case "$family" in
    virtual_os) name=virtual-execution-info; flag=--virtual_os_hints ;;
    aggregator) name=single-block; flag=--aggregator_input ;;
  esac
  cairo-vm-cli "$family.json" --layout all_cairo "$flag" "$name.json" --merge_extra_segments --cairo_pie_output "$name.zip"
  python3 -c 'import json,pathlib,sys; print(json.dumps({"tasks":[{"type":"CairoPiePath","path":str(pathlib.Path(sys.argv[1]).resolve()),"program_hash_function":"blake"}],"single_page":False}))' "$name.zip" > "$name.task.json"
  stwo_snapshot "$BOOTLOADER" "$name.snapshot" --bootloader "$name.task.json"
  ocaml_snapshot "$name.snapshot" "$name.input"
  RAYON_NUM_THREADS=1 prove --prover_input_path "$name.input" --proof_path "$name.proof.json" --params_json ../bench/reference/stwo/os-params.json
  verify --proof_path "$name.proof.json"
done
```

Here `stwo_snapshot` is the release build of `bench/stwo_snapshot.exe`. For an independent input comparison, substitute `raw_os_snapshot os.proof.json genesis.json rust.snapshot os all_cairo_stwo` for the direct exporter or `boot_snapshot "$BOOTLOADER" "$name.task.json" rust.snapshot` for each task exporter, adapt the resulting Rust snapshot, and compare the entire input file before proving.
