# Qualify a mainnet witness handoff

The archive owner selects Cairo 0 accounts, declares spanning at least two compiler versions, reverted transactions and blocks with large storage changes. For each block, run the independent state fold through a covering L1 anchor, prepare the SNOS witness and run the pinned Rust OS host on that witness. Keep private artifacts in the handoff directory. Send the digest of the finished manifest to the verifier over an authenticated channel.

```sh
python3 bench/qualify_os_host.py handoff/manifest.json \
  --trusted-sha256 "$MANIFEST_SHA256" --host /opt/oxcairo/oxcairo-os-host
```

The verifier checks each source file against the owner's inventory, compares the computed, header and anchored roots reported by the independent fold, and invokes the candidate once per witness. A passing receipt includes a full-archive SHA-256 shared by both implementations for every block. The fold and L1 observation happen upstream. Authenticating the manifest binds those observations to the run.

The manifest is JSON with `schema` equal to 1, `chain_id` equal to `SN_MAIN`, `cairo_vm` equal to `3.2.0`, the full sequencer `revision`, a `program` artifact and an array of `cases`. Each artifact has a relative `path` and a lowercase `sha256`. Each case records:

- `number`, `block_hash` and `state_root` from the mainnet header
- `categories`, chosen from `cairo0-account`, `declare`, `revert` and `large-storage`, and `declared_compiler_versions` for declares
- Recorded raw block `source`, `witness`, `rust_pie` and `fold_receipt` artifacts

The state-fold receipt records `chain_id`, `number`, `block_hash`, `derived_root` and `header_root` for the sampled block. Its `l1_anchor` records the anchor block as `covered_through`, the Ethereum `transaction_hash`, and the independently computed `derived_root` and L1-observed `contract_root` at that anchor. A later anchor covers an earlier block through a verified contiguous fold. State roots and block hashes are hexadecimal Stark field elements. Archive and witness digests identify the exact bytes used.

To derive a receipt from the original fold evidence, run `python3 bench/fold_receipt.py run.jsonl sampled-header.json l1-anchors.json --anchor-height HEIGHT`. Select each sampled block as a verified batch endpoint. A root observed only at the end of a larger batch qualifies that endpoint. The converter streams contiguous fold rows from genesis, checks the sample against its header and checks the covering `header+l1` row against the independently observed L1 update. Preserve the source files with the owner and include the generated receipt in the authenticated manifest.

The qualifier checks exact Rust and candidate ZIP equality and then reads their shared OS output header. The final state root, block number, and block hash must match the authenticated sample. Both sequencer pins place these words at output offsets 1, 3, and 5. The qualifier locates the output builtin using the program's builtin order and checks all ten header cells. It streams the 40-byte memory records with an 8 GiB uncompressed limit and accepts up to 8 MiB of program metadata. [Historical OS output parser](https://github.com/starkware-libs/sequencer/blob/1860b9850b5c51858c50c0f5038933e49f932eef/crates/starknet_os/src/io/os_output.rs#L249-L259) · [Current OS output parser](https://github.com/starkware-libs/sequencer/blob/ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45/crates/starknet_os/src/io/os_output.rs#L267-L277)

The receipt covers candidate execution on a prepared witness. Whole-job timing starts with the source input, before input decompression and class preparation.

## Time both complete jobs

On the dedicated Linux x86_64 runner, run `python3 bench/whole_os_job.py whole-job.json --output results.json`. Supply a schema 1 plan with `chain_id` set to `SN_MAIN`, the `hardware` description, `cache_policy`, the `qualification` artifact and its `qualified_manifest_sha256` (the handoff manifest digest reported inside the qualification). Each entry in `cases` has the qualified block `number` and its raw recorded `source` artifact. Include every qualified block. Use a fresh output path.

The `commands` object contains `rust` and `oxcairo`. Each has an `executable` artifact and an `arguments` array. The harness replaces the whole argument tokens `{source}`, `{output}` and `{work}` with absolute paths. Each adapter must acquire and decompress the recorded input, compile classes and prepare the witness using the same configuration, execute its respective VM, validate the PIE and publish it. Include stage timings from the host's own instrumentation when attributing time. The harness verifies full archive digests and records elapsed wall time and GNU time's maximum resident set size for each job. Kernel page caches are shared across arms. Each arm receives a fresh job directory.

The default is five paired, seeded, randomized rounds over all blocks. The summary reports each block's median Rust and candidate times, the median of their speedup ratios, and the ratio of the sums of the per-block medians. All individual observations are retained, including slower candidate runs. The plan, qualification, command digests, hardware and cache policy identify the measurement.

### Run the supplied offline Echonet pipeline

The `pipeline` plan option drives both engines through the same local-file job. It supports
sequencer `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45` and its bincode commitment decoder.
Use Python 3.10+, zstandard, the pinned Echonet cairo-lang dependencies for declares, and
GNU time on PATH. Keep the Python environment, compiler builds and flags in the runner's
build inventory. Store the installed engine binaries, Sierra compiler binaries and full
embedded OS program inside the handoff tree. Build the existing Rust example by copying
`bench/os_reference.rs` to the pin's `crates/starknet_os/examples/os_reference.rs` and running
`cargo build --locked --release -p starknet_os --features deserialize --example os_reference`.
Use the OxCairo release's native `cairo-vm-cli`.

Each authenticated `source` is one gzip JSON recording. See
`bench/examples/echonet-genesis.json` for a complete synthetic example before compression.
Record N's cende blob, N+1's numbered commitment vector, block document, header commitment
payload, chain name, and STRK address using the field names in that example. This measures
a recorded-input service starting at local file acquisition. Live RPC, upstream consensus,
calculation of the header commitment payload and remote delivery lie outside that boundary.
The handoff owner must qualify these exact compressed source bytes.

Include every required Cairo 0 class body in `deprecated_compiled_classes`, keyed by class
hash. For each required Sierra class, include its compiler-ready class JSON and compiler
identifier in `sierra`, keyed by compiled class hash, for example
`{"0xabc":{"compiler":"2.14.0","class":{...}}}`. Each arm recompiles each entry in its
own workspace with Pythonic hints and the all-libfunc list. Use the historical binary that
reproduces the qualified CASM. The upstream Echonet input builder assembles block hints.
The offline adapter fills its two class maps from the recording and the fresh compiler
outputs. The qualified witness controls the comparison, including the exact class inventory.
The checkpoint normalizes JSON object ordering and whitespace. All other JSON differences,
including a missing member versus an explicit null, fail the run.

Generate the plan alongside the manifest. Take the trusted digest from the archive owner
and the receipt from the successful qualification run. Supply one compiler argument per
historical tool your recordings require.

```sh
python3 bench/examples/echonet_plan.py handoff/manifest.json handoff/qualification.json \
  --trusted-sha256 "$MANIFEST_SHA256" --sequencer "$SEQUENCER_CHECKOUT" \
  --rust handoff/bin/os_reference --oxcairo handoff/bin/cairo-vm-cli \
  --compiler v1=handoff/bin/sierra-v1 --compiler v2=handoff/bin/sierra-v2 \
  --hardware "$RUNNER_DESCRIPTION" --cache-policy 'shared OS page cache, fresh job directory' \
  > handoff/whole-job.json
python3 bench/whole_os_job.py handoff/whole-job.json --output results.json
```

Each row includes monotonic nanoseconds for acquisition (including source check),
decompression, class compilation, witness preparation (including the witness check),
execution through the serial merged Rust-compatible ZIP writer, final archive validation
and durable local delivery. Both engines also produce public output to a discarded stream.
VM execution, VM finalization and ZIP encoding share one subprocess interval. Stage times
exclude interpreter startup and reporting, which are included in whole-job wall time.
The parent independently checks the complete delivered archive.

Run the synthetic integration example on Linux with the pinned git object available locally:

```sh
python3 test/whole_os_job_smoke.py "$SEQUENCER_CHECKOUT"
```

It exercises the real commitment decoder, witness builder, both engine argument lists,
GNU time, and the failure gates using local engine and compiler stand-ins.
