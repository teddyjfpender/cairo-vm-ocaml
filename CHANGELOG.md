# Changelog

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
