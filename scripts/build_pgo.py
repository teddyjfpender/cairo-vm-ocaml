#!/usr/bin/env python3
"""Build a native CLI with LLVM profiles from sequencer-produced OS witnesses."""

import argparse
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("os_program", type=Path, help="compiled Starknet os.cairo JSON")
    parser.add_argument("--output", type=Path, default=Path("_build/pgo/cairo-vm-cli"))
    parser.add_argument("--jobs", type=int, default=1, help="maximum concurrent Dune jobs")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    program = args.os_program.resolve(strict=True)
    output = args.output.resolve()
    root = Path(__file__).resolve().parents[1]
    profdata = shutil.which("llvm-profdata")
    if sys.platform == "darwin" and shutil.which("xcrun"):
        profdata = subprocess.check_output(["xcrun", "--find", "llvm-profdata"], text=True).strip()
    if not profdata:
        parser.error("llvm-profdata from the OCaml toolchain's Clang installation is required")

    def build(profile, directory, env):
        subprocess.run(["dune", "build", "--profile", profile, "--build-dir", directory,
                        "-j", str(args.jobs), "bin/main.exe"], cwd=root, env=env, check=True)
        return directory / "default/bin/main.exe"

    with tempfile.TemporaryDirectory(prefix="oxcairo-pgo-") as temporary:
        scratch = Path(temporary).resolve()
        env = os.environ.copy()
        env.pop("CAIRO_VM_RUST_CLI", None)
        cli = build("pgo-train", scratch / "train", env)
        raw = []
        for name in ("storage-512", "storage-2048", "syscalls-five-blocks", "syscalls-282"):
            witness = scratch / "input.json"
            with gzip.open(root / "test/fixtures/os" / (name + ".json.gz"), "rb") as src, witness.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            profile = scratch / (name + ".profraw")
            subprocess.run([cli, program, "--os_hints", witness, "--layout", "all_cairo"],
                           env=dict(env, LLVM_PROFILE_FILE=str(profile)), check=True)
            raw.append(profile)
        merged = scratch / "os.profdata"
        subprocess.run([profdata, "merge", "-o", merged, *raw], check=True)
        cli = build("pgo-use", scratch / "use", dict(env, OXC_PGO_PROFILE=str(merged)))
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as tmp:
            staged = Path(tmp.name)
        try:
            shutil.copy2(cli, staged)
            staged.replace(output)
        finally:
            staged.unlink(missing_ok=True)
    print(output)


if __name__ == "__main__":
    main()
