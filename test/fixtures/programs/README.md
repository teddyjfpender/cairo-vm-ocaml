# Starknet OS training program

`starknet-os-training.json.gz` contains the compiled Cairo program from the StarkWare sequencer at commit `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`. Its source is `crates/apollo_starknet_os_program/src/cairo/starkware/starknet/core/os/os.cairo`. The upstream repository and this project use Apache-2.0.

The fixture has the complete executable words, hints, identifiers, attributes and references. Its debug information was set to null to omit the build machine's source paths and unused source text. Its uncompressed SHA-256 is `e830720f26ce863ba027e8c73a6ab29a9a1e58edd5127fca80e0eed732067b28`. It supports offline profile training and execution-parity checks. Cold Rust comparisons use the complete compiler output embedded in the Rust reference.

Rebuild with the pinned sequencer's `apollo_starknet_os_program` crate. Its build script writes `starknet_os_bytes` under Cargo's build output. [Upstream source](https://github.com/starkware-libs/sequencer/tree/ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45/crates/apollo_starknet_os_program).

The native proof fixtures use `genesis.json`, `account.json.gz`, `reverted-invoke.json.gz` and `multi-block.json.gz` from the neighboring `os` directory. Decompress a gzip fixture before supplying it to the CLI.

The same sequencer build supplies the virtual OS and aggregator fixtures. Both retain all executable words and hints and omit compiler debug information.

- `virtual-os.json.gz` has uncompressed SHA-256 `8da31a0ac46149cb011afe35d2d6cd05bbb0c9fce3d6163c7eb7e184086b4d0b`.
- `aggregator.json.gz` has uncompressed SHA-256 `1b0ffd470a9acd987907a8a2bdc1c4627f24d8cbb57572cb2d1bdb39b1da1417`.
