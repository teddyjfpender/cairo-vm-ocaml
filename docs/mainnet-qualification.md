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
- `witness`, `rust_pie` and `fold_receipt` artifacts

The state-fold receipt records `chain_id`, `number`, `block_hash`, `derived_root` and `header_root` for the sampled block. Its `l1_anchor` records the anchor block as `covered_through`, the Ethereum `transaction_hash`, and the independently computed `derived_root` and L1-observed `contract_root` at that anchor. A later anchor covers an earlier block through a verified contiguous fold. State roots and block hashes are hexadecimal Stark field elements. Archive and witness digests identify the exact bytes used.

The receipt covers candidate execution on a prepared witness. Whole-job timing starts with the source input, before input decompression and class preparation.
