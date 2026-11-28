# Changelog

## 0.2.0 (release candidate)

- Execute Starknet OS, Virtual OS and block aggregation with the pinned sequencer's block witnesses. Coverage includes Cairo 0 and Cairo 1 calls, rollback, STRK transfers and blob commitments.
- Replay large OS PIEs with bounded memory, stream output archives, and embed secure replay through the versioned C API. The binary distribution includes the CLI, shared library and C header.
- Verify ten Stwo proofs, including direct OS genesis and multiblock proofs and four OS tasks inside the proof-mode bootloader. Independent Rust runs supply the reference execution artifacts.
- Load large compiler programs faster, reuse prepared programs between requests, and track class memory accesses directly during traced OS execution. End-to-end comparisons cover cold processes, persistent workers, artifact generation and large PIEs. Performance on repeated storage and short native scenarios remains below the across-the-board 10× goal. [0.2 qualification](docs/release-0.2.md)
- Accept omitted, null and empty attributes on historical Cairo 0 witnesses. OS and syscall hints share canonical field decoding and advance directly through multiblock witnesses.
- Require positive output and artifact evidence or matching reviewed diagnostics in differential tests. CI exercises missing artifacts, timeouts, crashes and oracle disagreements.
- Match Rust secure replay on reordered PIE memory and identical duplicates, including streamed input. Conflicting duplicates and missing cells fail validation.
- Include the proposed byte-oriented Rust replay API, C header and wrapper examples. The shipped C API uses file paths. [Snapshot ABI proposal](docs/proposals/pie-snapshot/README.md)

## 0.1.0 (2026-11-27)

First release of OxCairo, a Cairo VM in OCaml (OxCaml) and a drop-in replacement for the
`cairo-vm-cli` of starkware-libs/cairo-vm v4.0.0.

- **Parity with cairo-vm v4.0.0** on the upstream `cairo_programs` corpus: execution 155/165
  pass (the other 10 fail in both), proof mode 155/155, Cairo PIE output 138/148 (10 fail in
  both), Stwo opcode programs 2/2. Every compared output is byte-identical.
- **Coverage:** execution and proof mode, AIR public/private inputs, Cairo PIE output, all
  v4.0.0 layouts including `dynamic`, every builtin, Blake/BlakeFinalize/QM31 opcode extensions,
  v4.0.0's Stwo-only instruction set, temporary segments, and the full default hint table
  (including `EXCESS_BALANCE`).
- **Speed on Apple M5 Max vs Rust v4.0.0, 17 upstream benchmarks:** 6.05× for execution
  (6.65× mean per program) and 5.51× with trace and memory files. Proof mode runs on the
  native kernel.
- **Docs:** a Learn course with exercises, plus architecture, parity and benchmark pages
  (`scripts/docs.sh`).

Known limits: hints that exist only in Rust's `test_utils` build are rejected. Release
binaries link GMP dynamically (`brew install gmp` / `apt install libgmp10`).
