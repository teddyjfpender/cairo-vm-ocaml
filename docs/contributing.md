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
