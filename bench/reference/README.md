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
