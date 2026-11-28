# Parity

The general-purpose CLI uses Rust Cairo VM **v4.0.0** as its reference. Native Starknet OS, Virtual OS and aggregator checks use sequencer revision `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`, which uses Cairo VM **v3.2.0**. [Rust VM](https://github.com/starkware-libs/cairo-vm) · [Pinned sequencer](https://github.com/starkware-libs/sequencer/tree/ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45)

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

The current native parser rejects the malformed field. The gate checks Rust's
sequence-in-map parser error and OxCairo's `Invalid program metadata at instruction_locations`
diagnostic. This fixture previously executed on OxCairo v0.1.0.

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

### PIE replay

With `--from_pie`, the pinned Rust CLI writes a fresh PIE for each program. Every oracle
replays that same archive. The gate compares stdout, trace, memory and all output PIE
members. Failure to create a valid input archive fails the fixture.

```sh
python3 test/parity.py "$RUST" "$OCAML" corpus/ --from_pie \
  --expect-rejections test/parity_fixtures/rust-v4-replay-rejections.json
```

Four pinned v4.0.0 programs write beyond the final execution-segment extent recorded
by the Rust PIE producer. Inspection of the emitted `memory.bin` and `metadata.json`
gave the following occupied addresses and declared sizes.

| Program | Occupied address | Declared segment size |
| --- | ---: | ---: |
| `memory_holes` | 1:7 | 2 |
| `test_addition_if` | 1:5 | 5 |
| `test_reverse_if` | 1:7 | 7 |
| `test_subtraction_if` | 1:5 | 5 |

The PIE requires every occupied offset to be strictly less than its segment size.
The replay-only map requires both validators to exit 1 with their complete invalid-address
diagnostics and no output. These programs must still execute successfully and write
matching archives in source execution mode.

The Linux CI job also checks exact process exit codes with `test/cli_exit_codes.py`. Both CLIs must exit 0 on a valid program and 1 on the upstream `manually_compiled/overflowing_dict.json` and three generated metadata cases covering invalid debug locations, a numeric attribute value and duplicate `debug_info`.

## Version 0.2

| Comparison | Observed result |
| --- | --- |
| General execution and proof mode against Rust v4.0.0 | 150 matching runs in each mode |
| Re-execution from PIE | 146 matching runs and four inputs rejected by both runners |
| Stwo-only opcode programs | Both matched Rust |
| Sequencer fixtures | 25 native OS witnesses, four Virtual OS witnesses and 13 aggregator configurations matched their saved references |
| Binary trace and memory | Every byte matched Rust for seven OS-family workloads, including a 13,101,755-step storage run |
| Stwo proofs | Upstream verified four generic Cairo fixtures, four bootloader OS tasks and two direct OS executions |

Two direct account and revert witnesses use a builtin that is absent from the `all_cairo_stwo` layout. OxCairo and the pinned Rust runner reject both. Their bootloader executions produced verified proofs. [0.2 qualification and proof scope](release-0.2.md)

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
execution, storage writes and fee transfer. The account flow covers Declare, DeployAccount and Invoke, including an L2-to-L1 message.
A four-block variant of the storage flow ran 512 funded Invoke transactions in 3,417,265 steps.
The 2,048-transaction variant ran 13,101,755 steps. Both runners merged extra segments
for that fixture to fit the PIE address encoding. All three fixtures matched all five Rust PIE members. The sequencer’s alternating-inner-calls test ran 229,495 steps with SHA-256, SHA-512 and
KZG data availability enabled. The five-block new-syscalls flow ran 27 transactions and 1,163,403 steps. It exercises Keccak,
both secp256 curves, deterministic CASM elliptic-curve hints, circuit evaluation, and dictionary
squashing. All five archive members matched, including 50,537 memory holes. The scaled five-block fixture repeats the upstream Poseidon, Keccak, EC, secp256k1/r1, SHA and circuit invokes 16 times before advancing the state. Its 282 transactions ran 10,954,713 steps with 84,039 memory holes and matched all five sequencer PIE members. The saved reverted
Invoke and execution-info fixtures also match. Other transaction and syscall paths remain experimental.

Across 74 native inputs captured from the pinned upstream flow tests, 70 matched every Rust PIE member. The remaining four encrypted flows matched four members. Their memory contains freshly generated encryption keys and ciphertext. For all four encrypted cases, the sequencer decoded identical common OS output and plaintext state diffs from Rust and two independently seeded OCaml executions. In commitment mode the upstream validator also recomputed the KZG commitments, evaluations and challenge against each captured DA segment. The archive digests and input identities are in the [flow results](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/e559436e2589f1a10ce4fc6b3dac7a1cdbf4379c/test/fixtures/os/upstream-flow-results.csv). The checked-in suite includes deprecated calls, a meta-transaction and nested storage rollback.

The saved inputs and Rust archive member digests include the upstream flow tests
`test_initial_empty_block`, `test_load_bottom`, `test_new_account_flow` (calldata DA), and
512- and 2,048-transaction variants of `test_load_bottom`, with the chain ID encoded as
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

## Simple bootloader

The experimental `--bootloader_input FILE` option runs Cairo 0 programs and Cairo PIE
tasks inside the compiled simple bootloader shipped by `cairo-program-runner-lib 1.3.1`.
Use the crate's `resources/compiled_programs/bootloaders/simple_bootloader_compiled.json`
with `--proof_mode --layout starknet_with_keccak`. A task file contains a `tasks` array
and a `single_page` boolean. A task has a `type` of `RunProgramTask` or `CairoPiePath`,
a `path` to its input, and a `program_hash_function` of `pedersen`, `poseidon`, or `blake`.

The pinned Rust runner and OCaml produced identical stdout, relocated trace and memory for
an empty task list, Fibonacci under each program hash, EC-op, Keccak, signature programs,
the saved bitwise PIE and the sequencer's public ten-transfer virtual-OS PIE. Output page
sizes and fact-tree structure matched for the ten-transfer task. To repeat the saved bitwise
comparison, run `python3 test/fixtures/bootloader/check.py OCAML_CLI SIMPLE_BOOTLOADER_JSON`.
The Rust oracle is in `bench/bootloader_reference.rs`. It uses the pinned sequencer workspace
and the same crate, layout and trace padding.


The KZG hint uses the 4,096 compressed G1 monomial powers in the sequencer's
`crates/starknet_os/src/hints/hint_implementation/kzg/trusted_setup.txt` at the revision
above. The source text has SHA-256 `d39b9f2d047cc9dca2de58f264b6a09448ccd34db967881a6713eacacf0f26b7`.
To reproduce `src/os/kzg_monomial.bin`, skip the two count lines, 4,096 Lagrange G1 points
and 65 G2 points, then hex-decode and concatenate the final 4,096 lines in order. The
196,608-byte result has SHA-256 `08797579f6cfd5788eddc1a215d64dcfabd04acbcaf2953fb2c1afb830f43315`.

## Native Starknet aggregator

The native aggregator runs the compiled sequencer `aggregator/main.cairo` with
`--aggregator_input INPUT --layout all_cairo`. The input uses the sequencer's
`AggregatorInput` JSON format. In blob mode, `--aggregator_da_output FILE`
selects where the CLI writes the JSON array of blob coefficients.

The fixtures contain full OS outputs from four consecutive storage blocks and
five consecutive mixed-syscall blocks. Each block was first executed separately
by the pinned Rust sequencer. The native aggregator matched all five PIE
members for each chain in all four combinations of full or partial output and
calldata or blob DA. The four blob files also matched Rust byte for byte.

Run `python3 test/fixtures/aggregator/check.py OCAML_CLI AGGREGATOR_JSON` with
the compiled aggregator from sequencer commit
`ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`. The Rust reference entry point is
[aggregator_reference.rs](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/e559436e2589f1a10ce4fc6b3dac7a1cdbf4379c/bench/aggregator_reference.rs).

## Native virtual OS

Use the sequencer's compiled `virtual_os_bytes` as the program and pass
`--virtual_os_hints INPUT --layout all_cairo`. This selects the virtual OS runner, which checks Sierra gas tracking on root and nested
calls before executing. The message, execution-info and multicall fixtures
reproduce the pinned sequencer's five PIE members. The two multicall witnesses
contain sixteen and sixty-four repetitions of Keccak, EC and SHA-512 calls within one
transaction. Run the virtual suite with
`python3 test/fixtures/os/check.py OCAML_CLI VIRTUAL_OS_JSON --virtual-os`.
