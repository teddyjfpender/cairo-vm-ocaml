# Parity

The target is [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm) **v4.0.0**.

## How it's checked

[`test/parity.py`](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/main/test/parity.py)
runs the Rust and OCaml CLIs with identical flags on every compiled program in a corpus. It
compares stdout, trace, memory, AIR public/private inputs and PIE archives byte for byte. A
program passes when the outputs are identical, or when both VMs reject it.

```sh
python3 test/parity.py RUST_CLI OCAML_CLI corpus/ [--proof] [--pie] [-j N]
```

## Results

Upstream `cairo_programs`, compiled with cairo-lang 0.13.5:

| Mode | Pass | Fail in both | OCaml-only failures |
| --- | ---: | ---: | ---: |
| Execution, 165 programs | 155 | 10 | **0** |
| Proof mode (`starknet_with_keccak`), 155 programs | 155 | 0 | **0** |
| Cairo PIE output, 148 programs | 138 | 10 | **0** |
| Stwo opcode programs (Blake2s, QM31) | 2 | 0 | **0** |

## Supported

- Execution and proof mode, AIR public/private inputs, Cairo PIE output
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
