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

The Rust-encoded mainnet frames also matched the pinned Rust proof-mode execution for both heights. Checks compared the trace, relocated memory and public output byte for byte, and both AIR JSON documents structurally after excluding the two private filesystem paths. Two Virtual OS fixtures (execution info and 16 multicalls) matched Rust trace and relocated memory byte for byte. These checks qualify proof artifacts; they do not time a prover.

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
## Guarded resident worker

Six paired rounds used a clean integration of worker `4f7f256` and binary input `0da2c95` on macOS arm64 (merged tree `87df9245c35c490507ae310fe519efb37e471022`). The actual `oxcairo-os-worker pie-v1` executable SHA-256 was `76961f1b0c8450b56c12b25a98bc01a7a4ec61589d7660ae2b3d23cb7000fb50`. The packed program SHA-256 was `e3ec597c011f51959f393dad2aca33f943b068031cac0f6a4fe6ad3f1a7c04b0`. Each process accepted two requests after readiness. The request interval included per-job fork, limits, secure VM execution, stored ZIP writing, SHA-256, durable publication and the JSON reply. All 96 archives matched the corresponding reference bytes. Startup medians were approximately 11 ms and are accounted separately.

| First job → second job | Second, JSON input | Second, OXW1 input |
| --- | ---: | ---: |
| 16,000,001 → same | 71.21 ms | 67.34 ms |
| 16,149,540 → same | 179.50 ms | 186.27 ms |
| 16,000,001 → 16,149,540 | 168.98 ms | 162.60 ms |
| 16,149,540 → 16,000,001 | 70.47 ms | 88.89 ms |

The forked VM inherits the prepared program. Class-cache entries created inside one child belong to that child. The guarded run shows mixed format results across block sequences. [Worker receipts](guarded-jobs.jsonl)

Source encoding was timed independently using the Rust fixture adapter. Each path started from the same parsed native `serde_json::Value` model and wrote a new file through flush. The initial buffered parse of the saved JSON fixture took roughly 17 and 40 ms. That parse is outside both encoding and worker intervals. JSON encoding took **5.15 / 13.71 ms** on the small/large fixtures. The reference OXW1 encoder converted the tree into CBOR values and repacked every class. That took **15.48 / 36.63 ms**. These source figures describe the supplied fixture model; native node witness assembly has a different starting representation. [Source receipts](guarded-source.jsonl)
## Direct source encoding

The Rust producer now defaults to a writer that emits wire bytes directly from the already materialized witness. It writes length-delimited class maps and words into the output buffer, validates each hex nibble, and checks field range. The independent cbor4ii encoder remains available with `OXCAIRO_WITNESS_FORMAT=oxw`.

Six fresh, rotating three-way rounds repeated the source comparison. Each format started with the same in-memory witness value and wrote a new file through flush. No class or serialization cache was prepopulated.

| Mainnet block | JSON writer | Reference OXW1 writer | Direct OXW1 writer |
| ---: | ---: | ---: | ---: |
| 16,000,001 | 6.51 ms | 19.12 ms | **3.09 ms** |
| 16,149,540 | 15.95 ms | 45.50 ms | **7.52 ms** |

The direct encoder took about 47% of JSON encoding time on both blocks. Every binary result matched the retained OxCaml frame byte for byte. The fixture-source JSON parse medians were 18.6–18.9 ms for the smaller block and 43.3–43.9 ms for the larger one. Parsing is excluded from every encoding interval. These changes improve source serialization; the guarded worker still receives the same wire bytes. [Raw encoding receipts](direct-source.jsonl)
## Materialized witness through published PIE

A three-arm campaign measured one uninterrupted interval from an already materialized witness tree through source serialization, handoff and the worker's completion reply. Both JSON arms used the same native writer, and the binary arm used the direct OXW1 writer. All generated a fresh source file per request. The Rust reference used its production VM settings and retained its preloaded program. The guarded OxCairo supervisor retained its prepared program and enforced its per-job controls.

| First → second mainnet block | Rust, JSON | Guarded OxCairo, JSON | Guarded OxCairo, direct OXW1 | Paired Rust / direct OXW1 |
| --- | ---: | ---: | ---: | ---: |
| 16,000,001 → same | 142.56 ms | 78.15 ms | **73.71 ms** | **1.93×** |
| 16,149,540 → same | 345.87 ms | 186.18 ms | **170.07 ms** | **2.08×** |
| 16,000,001 → 16,149,540 | 346.96 ms | 182.62 ms | **172.24 ms** | **2.05×** |
| 16,149,540 → 16,000,001 | 148.19 ms | 77.54 ms | **75.51 ms** | **1.96×** |

Cells report second-job medians over six rounds, rotating all six engine/format orders. Ratios are medians of same-round pairs. Every timer covered serialization from the same native logical value, source file close, submission and the whole worker reply. The source serialization portion took approximately 2.9 / 6.1–6.2 ms for OXW1 and 5.5 / 12.5–12.8 ms for JSON on the smaller/larger jobs.

The Rust reference SHA-256 was `70b95939e3c9b8529851a5cf432c9a86f7acb587d9b8ca5768b2f18ecdf94d37`. The guarded worker identity is listed above. Rust replied after stored archive flush and close. OxCairo replied after isolation, limits, archive hashing, file fsync, atomic publication and directory fsync. Program startup and fixture hydration happened before the measured interval. Native node witness assembly remains outside this measurement.

Every job compared all five canonical PIE members after timing. Memory bytes and parsed JSON with arbitrary-precision numbers matched across all 144 jobs. All 96 guarded ZIPs also matched their retained reference bytes exactly. [First/second timings and subintervals](materialized-jobs.jsonl)

The `time-materialized` native driver accepts arm (`rust-json`, `ox-json`, `ox-direct`), worker, packed program, pinned digest, two fixture source paths, output path and corresponding reference ZIP paths. Host-side source assembly can replace its fixture hydration when a native node handoff is available.
