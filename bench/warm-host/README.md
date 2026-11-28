# Measure a warm, prepared-input PIE job

The native controller measures one request and completed reply at a time. All arms receive identical supplied witnesses. Each process retains its own prepared program and executes A, A, B, A with a new VM per request. Launch-to-ready and per-job timings use a monotonic wall clock. Arms rotate by round, starting input and request index. File caches remain warm. Each execution must reproduce the independently supplied unmerged reference PIE content. The checker parses all four JSON members with arbitrary precision and hashes the complete uncompressed memory bytes.

Build the controller with `cargo build --manifest-path bench/warm-host/Cargo.toml --release --locked` and the comparison adapter with `dune build --profile release bench/supplied_pie.exe`. The standard profile requires the pinned archive library used by the release package. The stored profile uses native uncompressed ZIP. The adapter also retains its existing batch invocation.

Install `bench/reference/supplied_pie.rs` as a manual example in a disposable pinned sequencer build. The example requires the Starknet OS deserialize feature and a direct dependency on the same 0.6 ZIP crate as cairo-vm. It forces the embedded program once at startup and calls the upstream stateless OS entry point for every accepted fixture. A downstream fork can supply its existing optimized Rust host through the same wire format. The embedded program must match the input oracle's program. A matching sequencer Git revision alone can admit different compiler outputs. The checker refuses mismatching PIE content.

Run `oxcairo-warm-host-bench CONFIG FRESH_OUTPUT_DIR` with a configuration like this:

```json
{
  "rounds": 6,
  "arms": [
    {"name":"rust","command":["/path/to/rust-supplied-pie","stored"]},
    {"name":"ox","command":["/path/to/supplied_pie.exe","/path/to/os.packed","--worker","stored"]},
    {"name":"guarded","publication":"stored","command":["/path/to/oxcairo-os-worker","pie-v1","/path/to/os.packed","--sha256","<file-sha256>"]}
  ],
  "cases": [
    {"name":"block-a","input":"/path/to/a.json","oracle":"/path/to/a-unmerged-pie.zip"},
    {"name":"block-b","input":"/path/to/b.json","oracle":"/path/to/b-unmerged-pie.zip"}
  ]
}
```

The guarded arm requires the native pie-v1 worker. For a run through the two benchmark adapters alone, use the first two arms. For matching standard DEFLATE set the benchmark adapters' profile to `standard` and the guarded publication to `rust-3.2`. Each ordinary adapter accepts a tab-separated witness and output path, and emits one JSON receipt. The guarded arm speaks the native JSONL protocol. A missing response or content mismatch fails the campaign. Every guarded receipt's byte count and whole-archive SHA-256 must match the independently read file. The controller deletes each validated scratch PIE and retains one JSONL timing row per job.

[Measured mainnet cases and raw results](../results/v0.3.0-m4-max/warm-prepared/README.md)
