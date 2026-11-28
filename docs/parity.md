# Parity

The target is [starkware-libs/cairo-vm](https://github.com/starkware-libs/cairo-vm) **v4.0.0**.

## Running the gate

`test/parity.py` runs each selected, top-level compiled JSON program with the same layout and flags
on each VM. Every fixture defaults to successful execution. To require a semantic rejection,
supply a reviewed JSON map from the fixture filename to a specific rejection class. Keep this
file outside the corpus. Select the expectations for the mode you are testing.

```sh
python3 test/test_parity.py -v
python3 test/parity.py "$RUST" "$OCAML" test/parity_fixtures/core \
  --expect-rejections test/parity_fixtures/core-rejections.json --verbose
python3 test/parity.py "$RUST" "$OCAML" proof-corpus/ --proof
python3 test/parity.py "$RUST" "$OCAML" corpus/ --pie
```

| Observation | Gate decision |
| --- | --- |
| Every VM exits 0 on a positive fixture | Compare stdout and every requested artifact. Any difference fails. |
| Every VM rejects a negative fixture | Each must exit 1 and match its complete, reviewed diagnostic for the named class, without emitting output. |
| Same unlisted rejection, wrong reason, or unexpected acceptance | Fail and print each VM's outcome. |
| Timeout, signal, panic, uncaught exception, unexpected exit or launch failure | Fail even when all VMs exhibit the same failure. |
| Missing, unreadable or malformed requested artifact | Fail even when every VM exhibits the same defect. |
| Empty selection, stale expectation, or unavailable requested oracle | Configuration error. |

Each VM gets fresh output paths. The harness unsets both Rust delegation variables. It compares
stdout directly and checks trace and memory lengths and SHA-256 digests. AIR public input retains
byte comparison outside the unordered `memory_segments` map. AIR private input must reference
the actual trace and memory before the remaining JSON is compared. PIE comparison checks the
required members and compares every uncompressed member by name and digest. These checks cover
presence, encoding and agreement. They do not validate a STARK proof.

The dependency-free regression suite uses subprocesses to inject timeouts, crashes, mismatched
rejections, missing outputs and oracle disagreements. The PR workflow also builds the candidate
OxCairo and pinned Rust CLI on Linux and runs the small real-VM corpus.
[Issue #46](https://github.com/teddyjfpender/cairo-vm-ocaml/issues/46) tracks broader CI coverage.

### Malformed-program regression

The core fixtures use a single `ret`. `wrong-prime.json` applies the existing
`test/cli/compare.py` mutation to that program, and `no-main.json` removes its entry point.
The malformed fixture changes only `debug_info.instruction_locations` from its implicit empty map
to an array. It is a separate reproducer for the validation gap in
[issue #45](https://github.com/teddyjfpender/cairo-vm-ocaml/issues/45).

```sh
python3 test/parity.py "$RUST" "$OCAML" test/parity_fixtures/malformed \
  --expect-rejections test/parity_fixtures/malformed-rejections.json --verbose
```

On OxCairo v0.1.0 this command exits 1: Rust rejects the sequence where a map is required and
OxCairo succeeds. When native validation lands, add its reviewed diagnostic for this class.
The repro should then turn green only when both enforce the same contract.

### Using the Lean executable semantics

Pass `--lean /path/to/adapter` to require a third result on **every selected fixture**. The
adapter is the integration point for a separately built, revision-pinned Lean VM. Build it
against the model's own loader, initial state, step function and finalization. Give it the
compiled program and CLI options directly. Produce observations from Lean state without
consuming the other CLIs' outputs, invoking them, or sharing their execution or relocation code.

```sh
python3 test/parity.py "$RUST" "$OCAML" test/parity_fixtures/core \
  --lean "$LEAN_ADAPTER" --expect-rejections test/parity_fixtures/core-rejections.json --verbose
```

1. Start with hint-free execution. The adapter receives
   `PROGRAM --layout L --print_output --trace_file T --memory_file M`.
   On success, print the exact program-output bytes and write each pre-step relocated
   `(ap, fp, pc)` as three little-endian u64s. Write initialized memory in ascending
   relocated-address order as little-endian u64 address and 32-byte field element pairs.
   The one-instruction return fixture provides a hand-checkable first vector. Its trace is
   `(4, 4, 1)`, its memory is `{1: 0x208b7fff7fff7ffe, 2: 4, 3: 4}`, and stdout is
   `Program Output:\n`.
2. Map typed Lean semantic errors to one stderr line, `reject wrong-field-prime` or
   `reject missing-main` for the core negatives, and exit 1. Rejecting an unsupported feature
   or exhausting model fuel is an oracle limitation. Return a distinct exit code such as 2.
   A missing, unsupported or timed-out Lean run fails a requested three-way gate.
3. Pin the model revision, adapter revision and fixture set in CI. Expand the three-way
   corpus as model support grows, starting with arithmetic, jumps, calls, returns and memory
   deduction before hints, builtins, proof mode and PIE. Keep the broader native suite running.
   The summary names the oracles exercised. A two-to-one split always fails and the report
   identifies the disagreeing pairs and artifacts.

The included test double exercises this protocol. A real three-way result requires the external
Lean executable and its adapter.

## Historical results

The original harness reported the following counts on upstream `cairo_programs` compiled
with cairo-lang 0.13.5. Its “fail in both” column included arbitrary nonzero exits and timeouts.
The identities and reasons for the ten shared failures require independent review before
they can enter a strict rejection manifest.

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
