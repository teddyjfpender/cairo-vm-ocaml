# Parity

The target is [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm) **v4.0.0**.

## How it's checked

[`test/parity.py`](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/test/parity.py)
runs the Rust and OCaml CLIs with identical flags on every compiled program in a corpus. It
compares stdout, trace, memory, AIR public/private inputs and PIE archives byte for byte. A
program passes when the outputs are identical, or when both VMs reject it.

```sh
python3 test/parity.py RUST_CLI OCAML_CLI corpus/ [--proof] [--pie] [--from_pie] [-j N]
```

`--from_pie` has the Rust CLI write each program's Cairo PIE first, then runs both CLIs with
`--run_from_cairo_pie` on it and also compares the PIEs they write.

## Results

Upstream `cairo_programs`, compiled with cairo-lang 0.13.5:

| Mode | Pass | Fail in both | OCaml-only failures |
| --- | ---: | ---: | ---: |
| Execution, 165 programs | 155 | 10 | **0** |
| Proof mode (`starknet_with_keccak`), 155 programs | 155 | 0 | **0** |
| Cairo PIE output, 148 programs | 138 | 10 | **0** |
| Stwo opcode programs (Blake2s, QM31) | 2 | 0 | **0** |
| Re-execution from a Cairo PIE, 155 PIEs | 151 | 4 | **0** |
| Four large Starknet OS PIEs and one virtual-OS PIE, re-executed | 5 | 0 | **0** |

The PIE rows compare stdout, trace, memory and every member of the output PIE. Ten corpus
programs have no PIE (Rust cannot write one). The Starknet OS PIEs are four OS runs of one
program (Blake program hash `0xb0134e…cd7`, 15,610 words) and the sequencer's 10-transfer
virtual-OS PIE (`0x602b02…ccb`, the 0.14.4 virtual OS). See [Benchmarks](benchmarks.md).

## Native sequencer execution

The experimental `--os_hints` option accepts a serialized `OsHints` object and a compiled
`os.cairo` program. Against sequencer revision
`ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`, the genesis, single-empty-block and
11-empty-block tests produced matching metadata, memory, builtin additional data, resource
counts and version bytes. These runs executed 7,007, 40,597 and 113,706 steps respectively.
The four-block storage test also matched all five PIE members after 196,893 steps.
It exercises funded Invoke transactions, modern account validation, nested Cairo 0 contract
execution, storage writes and fee transfer. Other transaction and syscall paths remain experimental.

The saved inputs and Rust archive member digests come from the upstream flow tests
`test_initial_empty_block` and `test_load_bottom`, with the chain ID encoded as
hex as required by the sequencer's input deserializer. To check the fixture, compile the
pinned checkout's `starkware/starknet/core/os/os.cairo` with cairo-lang 0.14.3a3, then run
`python3 test/fixtures/os/check.py _build/default/bin/main.exe /path/to/os.json`.

## Supported

- Execution and proof mode, AIR public/private inputs, Cairo PIE output
- Re-execution from a Cairo PIE (`--run_from_cairo_pie`, `Pie_file` and `Pie_run`), including
  the secure-run PIE compatibility check
- All v4.0.0 layouts, including `dynamic`
- Every builtin: output, pedersen, range_check, range_check96, ecdsa, bitwise, ec_op,
  keccak, poseidon, add_mod, mul_mod
- Blake, BlakeFinalize and QM31 opcode extensions
- v4.0.0's Stwo-only instruction set. Our classifier agrees with Rust's on all 130,230
  decodable instruction words we tested.
- Temporary segments and relocation rules
- The upstream hint table, generated from Rust's source by `scripts/gen_hint_codes.py`.
  The 13 feature-gated `cairo-0-secp-hints` codes are enabled with
  `CAIRO_VM_CAIRO0_SECP_HINTS=1`.
- The dex `EXCESS_BALANCE` hint, with rust_decimal's 96-bit rounding.
  `test/excess_balance/parity_programs.py` builds programs (including the upstream
  unit-test inputs) to compare with `test/parity.py`.

## Not yet

Hints that only exist in Rust's `test_utils` build fail with an explicit error.

!!! note
    Matching outputs on a corpus is strong evidence of compatibility, not a proof of it.
