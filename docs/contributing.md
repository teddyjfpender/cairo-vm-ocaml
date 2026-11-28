# Contributing

## Before opening a PR

Compatibility checks need `cairo-compile` 0.13.5 on `PATH`.

```sh
dune build --profile release && dune runtest --profile release
python3 test/parity.py /path/to/rust/cairo-vm-cli _build/default/bin/main.exe corpus/
python3 test/parity.py /path/to/rust/cairo-vm-cli _build/default/bin/main.exe proof-corpus/ --proof
```

A change must not introduce any `MISMATCH` or `OCAML_FAIL` rows.

## Performance claims

Back speed claims with paired, interleaved runs against a frozen baseline build:

```sh
python3 bench/compare_revisions.py BASE BASE CANDIDATE programs/*.json --rounds 6
```

`bench/repeat.exe PROGRAM.json N` runs a program N times in one process, which gives samplers
such as `sample` or `perf` enough data on short programs.

## Regenerated files

- `src/hints/hint_codes.ml`: `scripts/gen_hint_codes.py CAIRO_VM_CHECKOUT`
- `src/native/constants.h`: `scripts/gen_constants.py`

## Docs

`scripts/docs.sh` serves this site at http://127.0.0.1:8000 with live reload, and
`scripts/docs.sh build` writes it to `site/`. Both use `uvx`, so nothing is installed globally.

## Releases

1. Bump the version in `cairo-vm-ocaml.opam` and in `bin/main.ml`'s `--version` string, and add a
   `## X.Y.Z (date)` section to `CHANGELOG.md`.
2. Run `scripts/release.sh X.Y.Z`. It checks that the three agree, builds, runs the tests, then
   tags `vX.Y.Z` and pushes the tag.
3. `.github/workflows/release.yml` creates the GitHub release from the changelog section, builds
   and tests on macOS arm64 and Linux x86-64, and uploads `oxcairo-vX.Y.Z-<target>.tar.gz`
   with checksums.

## Upstream Cairo VM releases

**Watch upstream Cairo VM** checks the public version tags of `starkware-libs/cairo-vm` weekly on Mondays at 08:17 UTC. It covers tag-only release candidates, stable releases and maintenance branches. Each new tag and commit pair opens one OxCairo compatibility issue. Closing the issue records the decision; a moved tag opens a new issue for the new commit. The initial baseline suppresses historical tag/commit pairs. The watcher leaves the qualified references pinned until a maintainer reviews a compatibility PR.

Use **Run workflow** on the default branch to check immediately or catch up after a missed schedule. The checker scans the complete tag history on each run. GitHub can disable scheduled workflows in inactive public repositories; re-enable the workflow in Actions if scheduling is disabled. [Watcher and run history](https://github.com/teddyjfpender/cairo-vm-ocaml/actions/workflows/watch-cairo-vm.yml)
