#!/usr/bin/env bash
set -euo pipefail
adapter="$(cd "$(dirname "$0")" && pwd)/Adapter.lean"
cd "${LEAN_CAIRO_MODEL:?set to the pinned public formal-proofs checkout}"
test "$(git rev-parse HEAD)" = d0dd8279612a248cbc6bf6d286030bf0bb2a37ff
cd Stwo
# The public project is outside Mathlib's cache namespace. Request the actual
# Mathlib imports of Cpu/Instruction/Util/SimpAttr to avoid rebuilding their closure.
lake exe cache get Mathlib.FieldTheory.Finite.Basic Mathlib.Data.Fin.Basic \
  Mathlib.Tactic.Attr.Register Mathlib.Algebra.Field.ZMod
lake build Verification.Semantics.Cpu
lake env lean "$adapter"
