# OxCairo execution contract for v0.3.0

This contract applies to the candidate host generation and replay interfaces. A release qualification receipt names the exact compiler document, reference binary, input corpus and output profile for each comparison. The general Cairo CLI uses Rust Cairo VM v4.0.0. The SNOS host reference uses Cairo VM v3.2.0 and pins the OS independently.

## Observable execution

For a qualified successful run, the initialized segmented memory must agree cell for cell with Rust. A felt and a relocatable address have distinct types. Compare the segment and offset of every pointer, each memory access flag, the PC, AP and FP, each pre-step trace entry and the number of completed instructions. Relocated traces contain little-endian u64 AP, FP and PC in that order. Relocated initialized memory records contain an eight-byte address and a 32-byte little-endian field element. Public output is ordered.

For a failing instruction, compare the error class and step ordinal, registers, initialized memory, access flags, trace and completed steps at the refusal. An instruction may write individual cells before a later conflict. The independent Rust arm determines which writes survive and where a trace record is committed. Diagnostic prose, process IDs, allocation addresses, elapsed time and maximum RSS are outside the equality check.

## Hints, builtins and versions

| Surface | Reference and support boundary |
| --- | --- |
| General Cairo 0 | Builtin hint identifiers are registered in `src/hints`. Run `dune exec scripts/hint_coverage.exe -- program.json --unknown` to inventory a particular compiled program. Unknown hints are refusals. |
| Optional Cairo 0 hints | Nine upstream secp fixtures require `CAIRO_VM_CAIRO0_SECP_HINTS=1` for general execution. The reduced-multiplication data-availability hint is enabled in the native VM. |
| Main OS, Virtual OS and aggregator | Native hint handlers are bound to the compiled program in each qualification profile. Apollo 0.20.0-rc.1 is revision `1860b9850b5c51858c50c0f5038933e49f932eef`. The preceding profile is `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`. Use each program's manifest for its compiler, byte digest and hint inventory. |
| Layout builtins | Output, Pedersen, range check, ECDSA, bitwise, EC op, Keccak, Poseidon, range check 96, add mod and mul mod are selected by the compiled program and layout. See `src/runner/layout.ml` for layout-specific availability and ratios. |
| Cairo 1 | Typed hints are dispatched by their supported CASM variant. The upstream `DebugPrint` and deprecated hints outside the implemented variants have no qualification. |
| Proof mode | Compare proof-mode execution artifacts, including padded trace, memory, public input and private input. A proof verification receipt additionally identifies the Stwo prover and verifier and binds their success to those inputs. |
| Lean | The independent formal model qualifies the explicitly enumerated hint-free fixtures within its model and fuel limits. Ordinary SNOS hint execution is compared against the pinned Rust host. |

Native OS execution uses the pinned compiled program and witness. Witness preparation can require upstream class compilation, Blockifier re-execution, state reads and commitment proofs. The isolated host clears the Rust delegation environment. Running the host or replaying a PIE requires the packaged runtime dependencies. See [the host protocol](os-host.md) and [the parity gate](parity.md).

## Artifacts and failures

A complete archive comparison requires the same Rust publication profile on both sides. Compare the complete ZIP checksum in addition to canonical metadata, execution resources, builtin additional data and packed memory. Artifact comparisons retain every unfavorable or rejected case in the plan. Encrypted inputs require the same defined entropy for a deterministic comparison.

The versioned process host defines resource and input refusal classes, deadline and memory semantics, publication boundaries, concurrency and retry behavior. A worker signal, uncaught exception or timeout cannot satisfy an expected semantic rejection. An implementation fault reported as `internal_fault` fails qualification. [Process contract](os-host.md)

The process probe and normalized state schema are documented in `test/execution_contract/README.md`.

Run the installed-package checks for typed request validation, exact step boundaries, independent archive member digests, repeated and concurrent outputs, invalid field prime, truncated archives, output locking and recovery after interruption. The bounded request generator records its seed in `test/os_host.py`. Independently authenticated mainnet inputs require the corpus handoff and receipt checks. The handoff records the Rust and candidate full-archive digests at each admitted block.
