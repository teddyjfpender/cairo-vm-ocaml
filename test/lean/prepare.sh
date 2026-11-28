#!/usr/bin/env bash
set -euo pipefail
adapter="$(cd "$(dirname "$0")" && pwd)/Adapter.lean"
cd "${LEAN_CAIRO_MODEL:?set to the pinned public formal-proofs checkout}"
test "$(git rev-parse HEAD)" = d0dd8279612a248cbc6bf6d286030bf0bb2a37ff
cd Stwo
lake exe cache get Verification.Semantics.Cpu Mathlib.Algebra.Field.ZMod
lake build Verification.Semantics.Cpu
lake env lean "$adapter"
