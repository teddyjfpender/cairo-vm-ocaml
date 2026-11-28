# Changelog

## 0.2.0 (2026-11-28)

- Execute Starknet OS, Virtual OS and block aggregation with the pinned sequencer's block witnesses. Coverage includes Cairo 0 and Cairo 1 calls, rollback, STRK transfers and blob commitments.
- Replay large OS PIEs with bounded memory, stream output archives, and embed secure replay through the versioned C API. The binary distribution includes the CLI, prepared OS worker, shared library and C header.
- Verify ten Stwo proofs, including direct OS genesis and multiblock proofs and four OS tasks inside the proof-mode bootloader. Independent Rust runs supply the reference execution artifacts. The release assets include the ten verified proofs in `oxcairo-v0.2.0-stwo-proofs.tar.gz` and its SHA-256 checksum.
- Load large compiler programs faster, reuse prepared programs between requests, and track class memory accesses directly during traced OS execution. End-to-end comparisons cover cold processes, persistent workers, artifact generation and large PIEs. Performance on repeated storage and short native scenarios remains below the across-the-board 10× goal. [0.2 qualification](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/afc9719298d0d6e68743b5ab079eed602a3d1e9c/docs/release-0.2.md)
- Accept omitted, null and empty attributes on historical Cairo 0 witnesses. OS and syscall hints share canonical field decoding and advance directly through multiblock witnesses.
- Require positive output and artifact evidence or matching reviewed diagnostics in differential tests. CI exercises missing artifacts, timeouts, crashes and oracle disagreements.
- Match Rust secure replay on reordered PIE memory and identical duplicates, including streamed input. Conflicting duplicates and missing cells fail validation.
- Include the proposed byte-oriented Rust replay API, C header and wrapper examples. The shipped C API uses file paths. [Snapshot ABI proposal](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/2b46322ff607d0c326c9006d845f87817d908acb/docs/proposals/pie-snapshot/README.md)
- Stream repeated Cairo dictionary accesses in the native execution loop, retaining checked memory and step accounting. [Dictionary execution measurements](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/52)
- Match Rust v4 rejection of malformed compiler metadata across 18 previously differing cases. [Loader parity tests](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/53)
- Test the extracted CLI, worker and C replay library on both supported platforms before publication. The smoke test runs the native genesis witness and compares all five PIE members with Rust. [Installed-package test](https://github.com/teddyjfpender/cairo-vm-ocaml/pull/54)

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
