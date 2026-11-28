# Native witness interoperability

The independent Rust producer uses cbor4ii's native CBOR values. It converts integral fixtures to the OXW1 data model and emits framed class maps and compact CASM word vectors. A host can build those values directly from its prepared witness structures. The reference fixture converter accepts hexadecimal CASM words and numeric literals representable by exact 64-bit integers. The packaged OxCaml CLI supports the full wire profile. [Wire contract](../../../docs/witness-wire.md)

```sh
cargo build --locked --release --manifest-path bench/reference/witness-wire/Cargo.toml
bench/reference/witness-wire/target/release/witness-interop prepared.json rust.oxw
dune exec --profile release bin/main.exe -- --pack_os_witness ocaml.oxw prepared.json
cmp rust.oxw ocaml.oxw
```

Both encoders produced identical frames on complete mainnet witnesses from the Apollo 1860b985 OS. Both inputs reproduced the retained stored PIE archives byte for byte.

| Mainnet height | JSON bytes | OXW1 bytes | OXW1 SHA-256 | Stored PIE SHA-256 |
| ---: | ---: | ---: | --- | --- |
| 16,000,001 | 4,368,481 | 2,317,562 | `846ff8a20c1214e835afdbb92932b27f8de6573de088a338766191de2eb875d0` | `5efea3728ae530388b4ff69726b378f9d7e2b31e200557291c40b53ce724e855` |
| 16,149,540 | 10,143,851 | 5,585,132 | `9ad4c5a7186da93d21f96270200f512e60a4391ac4d2e656f7314f4d9c20e80f` | `a61b35662baf7868448e3f721ac90ead215f42edd2337e8bc69d6e65c9fdaca3` |

## First and second jobs

Six paired rounds on a macOS arm64 M4 Max rotated format order and first block. Each process prepared the program once. Each job read its own supplied input, initialized a fresh secure VM, ran the OS, finalized and wrote an uncompressed PIE. After stopping the clock it compared that archive against the independent stored reference. Program preparation, witness assembly, conversion, supervision, fsync and proof generation are outside the measured interval. JSON can defer selected subtrees until execution. The read column measures initial reading. Total time includes deferred work.

| First → second block | Job | JSON read | OXW1 read | JSON total | OXW1 total |
| --- | --- | ---: | ---: | ---: | ---: |
| 16,000,001 → same | First | 6.44 ms | 7.66 ms | 54.10 ms | 51.48 ms |
| 16,000,001 → same | Second | 4.56 ms | 0.68 ms | 47.94 ms | 43.77 ms |
| 16,149,540 → same | First | 16.19 ms | 20.65 ms | 128.66 ms | 126.86 ms |
| 16,149,540 → same | Second | 7.30 ms | 9.46 ms | 124.60 ms | 119.70 ms |
| 16,000,001 → 16,149,540 | Second | 18.31 ms | 13.85 ms | 127.39 ms | 121.55 ms |
| 16,149,540 → 16,000,001 | Second | 0.93 ms | 0.80 ms | 58.67 ms | 49.72 ms |

Cells are medians of six timings. The repeated larger witness had slower initial binary decoding on its second job. On distinct blocks the 4- and 9-class sets shared three classes. All 96 measured jobs passed archive equality. This campaign compares the two formats on the same OxCairo VM. [Raw pairs](jobs.csv)

To reproduce a pair, pass both prepared witnesses and both independently qualified archives in the same order. Use the same blocks for JSON and OXW1.

```sh
dune exec --profile release bench/witness_decode.exe -- \
  program.json first.oxw second.oxw result.zip first-reference.zip second-reference.zip 2
```
