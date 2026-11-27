"""Time native OS execution from block inputs using a pinned run_os_stateless reference."""
import argparse
import csv
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile


PRIME = 2**251 + 17 * 2**192 + 1


def run(command):
    start = time.perf_counter()
    env = os.environ.copy()
    env.pop("CAIRO_VM_RUST_CLI", None)
    output = subprocess.check_output(command, text=True, env=env)
    elapsed = time.perf_counter() - start
    fields = [int(line, 0) % PRIME for line in output.splitlines()
              if line and line != "Program Output:"]
    return elapsed, fields


def compare_archive(left, right):
    with zipfile.ZipFile(left) as a, zipfile.ZipFile(right) as b:
        if sorted(a.namelist()) != sorted(b.namelist()):
            raise ValueError("PIE member lists differ")
        for name in a.namelist():
            with a.open(name) as x, b.open(name) as y:
                while True:
                    data = x.read(1024 * 1024)
                    if data != y.read(1024 * 1024):
                        raise ValueError(f"PIE member differs: {name}")
                    if not data:
                        break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ocaml", "rust", "program"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(["case", "mode", "pair", "first", "rust_s", "ocaml_s", "speedup"])
    with tempfile.TemporaryDirectory() as directory:
        archives = {vm: Path(directory) / f"{vm}.zip" for vm in ("ocaml", "rust")}
        for path in args.inputs:
            source = path
            if path.suffix == ".gz":
                source = Path(directory) / "os-input.json"
                with gzip.open(path, "rb") as compressed, source.open("wb") as uncompressed:
                    shutil.copyfileobj(compressed, uncompressed)
            for mode in ("pie", "output"):
                commands = {"ocaml": [args.ocaml.resolve(), args.program, "--layout", "all_cairo",
                                      "--os_hints", source, "--print_output"],
                            "rust": [args.rust.resolve(), source]}
                if mode == "pie":
                    commands["ocaml"] += ["--cairo_pie_output", archives["ocaml"]]
                    commands["rust"].append(archives["rust"])
                for i in range(args.pairs):
                    order = ("rust", "ocaml") if i % 2 == 0 else ("ocaml", "rust")
                    result = {vm: run(commands[vm]) for vm in order}
                    (r, rf), (o, of) = result["rust"], result["ocaml"]
                    if rf != of:
                        raise ValueError("OS output differs")
                    if mode == "pie":
                        compare_archive(archives["rust"], archives["ocaml"])
                    writer.writerow([path.name.split(".json")[0], mode, i + 1, order[0],
                                     f"{r:.6f}", f"{o:.6f}", f"{r / o:.3f}"])
                    sys.stdout.flush()


if __name__ == "__main__":
    main()
