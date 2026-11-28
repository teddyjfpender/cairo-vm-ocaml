# Exact Cairo VM 3.2.0 archives

Run the compiled OS, Virtual OS or aggregator with `--cairo_pie_output result.zip --pie_profile rust-3.2` to request the registry Cairo VM 3.2.0 ZIP encoding. The default fast profile retains its independent stored and parallel DEFLATE encodings. The pinned profile fixes the compression level and atomically publishes the completed ZIP.

The OCaml VM produces the members in this order: version.json, metadata.json, memory.bin, additional_data.json and execution_resources.json. Each memory record contains its eight-byte little-endian encoded address and 32-byte little-endian typed value. The container uses zip 0.6.6, default DEFLATE level, large-file local extra fields, the Unix creator and permissions, and a fixed 1980-01-01 timestamp. The linked library uses flate2 1.1.9 and miniz_oxide 0.8.9 from Cargo.lock. It receives serialized member contents from the OCaml VM. It contains no Cairo VM, execution or witness logic.

Release builds include the statically linked archive library and redistribution notices. To enable it from source, run the following before building with Dune. Rust and Cargo are build dependencies of the pinned profile. General OCaml builds can omit this library.

```sh
export OXC_PIE_ARCHIVE="$(python3 scripts/build_pie_archive.py /absolute/path/to/pie-archive)"
dune build --profile release bin/main.exe test/exact_pie/replay_encrypted.exe
python3 test/exact_pie/check.py _build/default/bin/main.exe _build/default/test/exact_pie/replay_encrypted.exe
```

The fixture digests bind the entire ZIP, ordered uncompressed members, relocated trace and relocated memory. The check runs all fixtures with one and two independent VM worker processes. On a match, every observed byte agrees with the pinned reference digest. CI runs the same checks on Ubuntu x86-64 and macOS arm64.

## Reference generation

The ordinary archive references used the stock sequencer revision ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45, registry Cairo VM 3.2.0, and the repository's bench/os_reference.rs, bench/virtual_os_reference.rs and bench/aggregator_reference.rs entry points. Each received the decompressed versioned witness and wrote its unmodified production ZIP. The separate bench/reference/os_traced.rs example emitted the trace and relocated memory. Its invocation is `os_traced os|virtual-os|aggregator witness.json output-directory`. The ordinary cases cover genesis, a reverted invoke, Virtual OS and aggregation.

Encryption uses fresh operating-system randomness in both production implementations. The encrypted one-block fixture uses public test keys. For its reference only, the sequencer's calculate_keys_using_sha256_hash received bytes 0 through 31 in order in place of its single SysRng call. The reference ran the usual key derivation, OS, output checks and archive writer. The OCaml test driver supplies the same bytes and asserts exactly one entropy draw. No CLI or service option selects these test bytes.

An authorized library caller can supply its own previously recorded private entropy via Os_hints.initialize's optional entropy_source callback. Each invoked key-generation hint consumes exactly 32 bytes. Protect a real entropy transcript as secret key material and reject unexpected, missing or unused draws. Independent fresh encrypted executions can verify public output semantics and decrypted state, but reproducible bytes require an identical private transcript.
