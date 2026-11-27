#!/bin/sh
# Cut a release: scripts/release.sh X.Y.Z
# Checks the version is consistent and the build/tests pass, then tags and pushes;
# .github/workflows/release.yml builds the binaries and publishes the GitHub release.
set -eu
v=${1:?usage: scripts/release.sh X.Y.Z}
cd "$(dirname "$0")/.."
grep -q "^version: \"$v\"" cairo-vm-ocaml.opam || { echo "opam version is not $v"; exit 1; }
grep -q "OxCairo $v" bin/main.ml || { echo "bin/main.ml --version is not $v"; exit 1; }
grep -q "^## $v " CHANGELOG.md || { echo "CHANGELOG.md has no '## $v' section"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
dune build --profile release && dune test --profile release
git tag -a "v$v" -m "OxCairo $v"
git push origin "v$v"
