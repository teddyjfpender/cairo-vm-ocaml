#!/usr/bin/env bash
# Run as the image's unprivileged opam user in a fresh container.
set -euo pipefail
export LC_ALL=C TZ=UTC
export OPAMROOT=/home/opam/release-opam OPAMSWITCH=release OPAMJOBS=3 OPAMYES=1
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -c safe.directory=/checkout -C /checkout log -1 --format=%ct)
mkdir /home/opam/source
git -c safe.directory=/checkout -C /checkout archive HEAD | tar -xf - -C /home/opam/source
cd /home/opam/source
source scripts/reproducible/sources.env
unset OPAMSWITCH
opam init --bare --no-setup --disable-sandboxing default "git+https://github.com/ocaml/opam-repository.git#$OPAM_REPOSITORY"
opam repository add ox "git+https://github.com/oxcaml/opam-repository.git#$OX_REPOSITORY" --dont-select
opam switch create release --repositories=ox,default --packages=ocaml-variants.5.2.0+ox
export OPAMSWITCH=release
opam install dune.3.25.0 zarith.1.14+ox yojson.2.2.2+ox
opam list --installed --columns=name,version --short | awk '{print $1 "." $2}' | sort > /tmp/resolved.lock
diff -u scripts/reproducible/opam-packages.lock /tmp/resolved.lock
eval "$(opam env)"
dune build --profile release -j 3 bin/main.exe bench/native_os_worker.exe bindings/c/oxcairo.so
tag="v$(sed -n 's/^version: "\(.*\)"/\1/p' cairo-vm-ocaml.opam)"
python3 scripts/package_release.py "$tag" linux-x86_64 _build/default/bin/main.exe --worker _build/default/bench/native_os_worker.exe --library _build/default/bindings/c/oxcairo.so --output-dir /out
archive=/out/oxcairo-$tag-linux-x86_64.tar.gz
python3 scripts/smoke_release.py "$archive"
python3 scripts/reproducible/provenance.py "$archive"
