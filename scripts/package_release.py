#!/usr/bin/env python3
"""Package an already-built CLI, prepared OS worker and replay library without tagging or publishing."""

import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="release tag, e.g. v0.2.0")
    parser.add_argument("target", choices=["macos-arm64", "linux-x86_64"])
    parser.add_argument("cli", type=Path)
    parser.add_argument("--worker", type=Path, help="include the prepared OS worker executable")
    parser.add_argument("--library", type=Path, default=Path("_build/default/bindings/c/oxcairo.so"))
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        parser.error("expected a vX.Y.Z tag")
    version = subprocess.check_output([args.cli.resolve(), "--version"], text=True)
    if f"(OxCairo {args.tag[1:]})" not in version:
        parser.error(f"{args.cli} reported {version.strip()}")
    root = Path(__file__).resolve().parents[1]
    files = {name: root / name for name in ("README.md", "CHANGELOG.md", "LICENSE",
                                                  "docs/os-host.md", "docs/EXECUTION_CONTRACT.md")}
    files.update({"oxcairo-os-host": root / "host/oxcairo-os-host", "cairo-vm-cli": args.cli, "lib/oxcairo.so": args.library,
                  "include/oxcairo.h": root / "bindings/c/oxcairo.h"})
    if args.worker is not None:
        files["oxcairo-os-worker"] = args.worker
    for variable, source, name in [("OXC_LIBDEFLATE", "COPYING", "libdeflate"),
                                   ("OXC_OPENSSL", "LICENSE.txt", "openssl")]:
        prefix = os.environ.get(variable)
        if prefix and prefix != "system":
            files[f"licenses/{name}.txt"] = Path(prefix) / source
    if os.environ.get("OXC_PIE_ARCHIVE"):
        notices = Path(os.environ["OXC_PIE_ARCHIVE"]).parent / "licenses"
        for notice in notices.iterdir():
            files[f"licenses/pie-archive/{notice.name}"] = notice
    name = f"oxcairo-{args.tag}-{args.target}"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    archive = args.output_dir / (name + ".tar.gz")
    with tempfile.NamedTemporaryFile(dir=args.output_dir, delete=False) as tmp:
        staged = Path(tmp.name)
    try:
        with staged.open("wb") as out, gzip.GzipFile(filename="", fileobj=out, mode="wb", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w|") as tar:
                for member, path in sorted(files.items()):
                    info = tarfile.TarInfo(f"{name}/{member}")
                    info.mode = 0o755 if member in ("cairo-vm-cli", "oxcairo-os-host", "oxcairo-os-worker", "lib/oxcairo.so") else 0o644
                    info.size = path.stat().st_size
                    with path.open("rb") as data:
                        tar.addfile(info, data)
        with staged.open("rb") as data:
            digest = hashlib.file_digest(data, "sha256").hexdigest()
        staged.chmod(0o644)
        staged.replace(archive)
        archive.with_suffix(".gz.sha256").write_text(f"{digest}  {archive.name}\n")
    finally:
        staged.unlink(missing_ok=True)
    print(archive)


if __name__ == "__main__":
    main()
