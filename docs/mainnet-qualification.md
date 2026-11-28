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

The receipt covers candidate execution on a prepared witness. Whole-job timing starts with the source input, before input decompression and class preparation.

## Time both complete jobs

On the dedicated Linux x86_64 runner, run `python3 bench/whole_os_job.py whole-job.json --output results.json`. Supply a schema 1 plan with `chain_id` set to `SN_MAIN`, the `hardware` description, `cache_policy`, the `qualification` artifact and its `qualified_manifest_sha256` (the handoff manifest digest reported inside the qualification). Each entry in `cases` has the qualified block `number` and its raw recorded `source` artifact. Include every qualified block. Use a fresh output path.

The `commands` object contains `rust` and `oxcairo`. Each has an `executable` artifact and an `arguments` array. The harness replaces the whole argument tokens `{source}`, `{output}` and `{work}` with absolute paths. Each adapter must acquire and decompress the recorded input, compile classes and prepare the witness using the same configuration, execute its respective VM, validate the PIE and publish it. Include stage timings from the host's own instrumentation when attributing time. The harness verifies full archive digests and records elapsed wall time and GNU time's maximum resident set size for each job. Kernel page caches are shared across arms. Each arm receives a fresh job directory.

The default is five paired, seeded, randomized rounds over all blocks. The summary reports each block's median Rust and candidate times, the median of their speedup ratios, and the ratio of the sums of the per-block medians. All individual observations are retained, including slower candidate runs. The plan, qualification, command digests, hardware and cache policy identify the measurement.
