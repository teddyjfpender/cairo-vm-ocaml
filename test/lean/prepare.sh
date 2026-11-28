#!/usr/bin/env bash
set -euo pipefail
adapter="$(cd "$(dirname "$0")" && pwd)/Adapter.lean"
cd "${LEAN_CAIRO_MODEL:?set to the pinned cairo-vm-lean checkout}"
test "$(git rev-parse HEAD)" = 6cae3dd895e89ddde776b589ad2612b0f71d96b1
git submodule update --init --depth 1 upstream/formal-proofs
test "$(git -C upstream/formal-proofs rev-parse HEAD)" = d0dd8279612a248cbc6bf6d286030bf0bb2a37ff
# Cache only the mathematical dependencies of the selected runner and deduction step.
lake exe cache get Mathlib.Algebra.BigOperators.Fin Mathlib.Algebra.Field.ZMod \
  Mathlib.AlgebraicGeometry.EllipticCurve.Affine.Point Mathlib.Data.Int.ModEq Mathlib.Data.Nat.Size \
  Mathlib.FieldTheory.Finite.Basic Mathlib.NumberTheory.LucasPrimality Mathlib.Tactic.LinearCombination \
  Mathlib.Tactic.NormNum.Prime Mathlib.Tactic.ReduceModChar Mathlib.Tactic.Ring
lake build CairoVM.Runner.Execute CairoVM.Execution.Deduction
lake env lean "$adapter"
