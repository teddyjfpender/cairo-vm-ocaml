"""Compare repeated block execution in fresh VMs inside persistent OS runner processes."""
import argparse
from contextlib import ExitStack
import csv
import gzip
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from compare_native_os import PRIME, embedded_program_digest


def run(worker):
    start = time.perf_counter()
    worker.stdin.write("RUN\n")
    worker.stdin.flush()
    words = []
    for line in worker.stdout:
        if line == "DONE\n":
            return time.perf_counter() - start, words
        words.append(int(line.strip(), 0) % PRIME)
    raise RuntimeError(f"Worker exited with status {worker.wait()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ocaml", "rust", "program"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    try:
        program_hash = embedded_program_digest(args.rust, args.program)
    except ValueError as error:
        parser.error(str(error))
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(["case", "pair", "first", "rust_s", "ocaml_s", "speedup", "program_sha256"])
    for source in args.inputs:
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            path = source
            if source.suffix == ".gz":
                path = Path(temp) / "os-input.json"
                with gzip.open(source, "rb") as compressed, path.open("wb") as raw:
                    shutil.copyfileobj(compressed, raw)
            workers = {}
            commands = {"rust": [args.rust.resolve(), "--worker", path],
                        "ocaml": [args.ocaml.resolve(), args.program, path]}
            for name, command in commands.items():
                proc = stack.enter_context(subprocess.Popen(command, stdin=subprocess.PIPE,
                                                           stdout=subprocess.PIPE, text=True))
                stack.callback(proc.stdin.close)
                if proc.stdout.readline() != "READY\n":
                    raise RuntimeError(f"{name} did not initialize")
                workers[name] = proc
            for i in range(args.pairs + 1):
                order = ("rust", "ocaml") if i % 2 else ("ocaml", "rust")
                pair = {name: run(workers[name]) for name in order}
                r, o = pair["rust"], pair["ocaml"]
                if r[1] != o[1]:
                    raise ValueError(f"OS output differs for {source}")
                if i:
                    out.writerow([source.name.split(".json")[0], i, order[0], f"{r[0]:.6f}",
                                  f"{o[0]:.6f}", f"{r[0]/o[0]:.3f}", program_hash])
                    sys.stdout.flush()


if __name__ == "__main__":
    main()
