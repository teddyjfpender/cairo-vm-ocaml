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
    parser.add_argument("os_program", nargs="?", type=Path, help="compiled OS JSON (defaults to the pinned training program)")
    parser.add_argument("--output", type=Path, default=Path("_build/pgo/cairo-vm-cli"))
    parser.add_argument("--worker-output", type=Path, help="also build the persistent benchmark worker with the same profile")
    parser.add_argument("--jobs", type=int, default=1, help="maximum concurrent Dune jobs")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    output = args.output.resolve()
    worker = args.worker_output.resolve() if args.worker_output else None
    if worker == output:
        parser.error("--worker-output and --output must be distinct")
    root = Path(__file__).resolve().parents[1]
    profdata = shutil.which("llvm-profdata")
    if sys.platform == "darwin" and shutil.which("xcrun"):
        profdata = subprocess.check_output(["xcrun", "--find", "llvm-profdata"], text=True).strip()
    if not profdata:
        parser.error("llvm-profdata from the OCaml toolchain's Clang installation is required")

    def build(profile, directory, env, targets):
        subprocess.run(["dune", "build", "--profile", profile, "--build-dir", directory,
                        "-j", str(args.jobs), *targets], cwd=root, env=env, check=True)
        return directory / "default"

    def install(binary, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as tmp:
            staged = Path(tmp.name)
        try:
            shutil.copy2(binary, staged)
            staged.replace(destination)
        finally:
            staged.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="oxcairo-pgo-") as temporary:
        scratch = Path(temporary).resolve()
        if args.os_program is None:
            program = scratch / "training-program.json"
            with gzip.open(root / "test/fixtures/programs/starknet-os-training.json.gz", "rb") as src, program.open("wb") as dst:
                shutil.copyfileobj(src, dst)
        else:
            program = args.os_program.resolve(strict=True)
        env = os.environ.copy()
        env.pop("CAIRO_VM_RUST_CLI", None)
        cli = build("pgo-train", scratch / "train", env, ["bin/main.exe"]) / "bin/main.exe"
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
        targets = ["bin/main.exe"]
        if worker:
            targets.append("bench/native_os_worker.exe")
        binaries = build("pgo-use", scratch / "use", dict(env, OXC_PGO_PROFILE=str(merged)), targets)
        install(binaries / targets[0], output)
        if worker:
            install(binaries / targets[1], worker)
    print(output)


if __name__ == "__main__":
    main()
