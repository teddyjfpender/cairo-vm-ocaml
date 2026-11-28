#!/usr/bin/env bash
# Run as the image's unprivileged opam user in a fresh container.
set -euo pipefail
export LC_ALL=C TZ=UTC OXC_TARGET_CPU=x86-64
unset OXC_OPENSSL OXC_LIBDEFLATE
export OPAMROOT=/home/opam/release-opam OPAMSWITCH=release OPAMJOBS=3 OPAMYES=1
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -c safe.directory=/checkout -C /checkout log -1 --format=%ct)
mkdir /home/opam/source
git -c safe.directory=/checkout -C /checkout archive HEAD | tar -xf - -C /home/opam/source
cd /home/opam/source
source scripts/reproducible/sources.env
# The base image fixes the initial dpkg state. The signed snapshot fixes all extra packages.
for suite in noble noble-updates noble-security; do
  echo "deb https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/ $suite main universe"
done > /tmp/oxcairo-packages.list
apt_opts=(-o Dir::Etc::sourcelist=/tmp/oxcairo-packages.list -o Dir::Etc::sourceparts=- -o Acquire::Check-Valid-Until=false)
sudo apt-get "${apt_opts[@]}" update
sudo apt-get "${apt_opts[@]}" install -y --no-install-recommends autoconf automake libgmp-dev zlib1g-dev
export OPAMNODEPEXTS=1
unset OPAMSWITCH
opam init --bare --no-setup --disable-sandboxing default "git+https://github.com/ocaml/opam-repository.git#$OPAM_REPOSITORY"
opam repository add ox "git+https://github.com/oxcaml/opam-repository.git#$OX_REPOSITORY" --dont-select
opam switch create release --repositories=ox,default --packages=ocaml-variants.5.2.0+ox
export OPAMSWITCH=release
# The pinned overlay names a mutable git branch for Zarith. Retain its build metadata
# and replace only that URL with the verified archive of the selected source revision.
repo=/home/opam/release-lock
mkdir -p "$repo/packages/zarith/zarith.1.14+ox"
echo 'opam-version: "2.0"' > "$repo/repo"
opam show --raw zarith.1.14+ox | sed \
  "s|src: \"git+https://github.com/avsm/zarith.git#oxcaml\"|src: \"https://codeload.github.com/avsm/zarith/tar.gz/$ZARITH_COMMIT\" checksum: \"sha256=$ZARITH_ARCHIVE_SHA256\"|" \
  > "$repo/packages/zarith/zarith.1.14+ox/opam"
grep -Fq "$ZARITH_ARCHIVE_SHA256" "$repo/packages/zarith/zarith.1.14+ox/opam"
opam repository add locked-source "$repo"
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
