"""Compare repeated block execution in fresh VMs inside persistent OS runner processes."""
import argparse
from contextlib import ExitStack
import csv
import gzip
import random
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


def workers_for(args, path, stack):
    mode = [] if args.kind == "os" else ["--" + args.kind]
    commands = {"rust": [args.rust.resolve(), *mode, "--worker", path],
                "ocaml": [args.ocaml.resolve(), args.program, path, *mode]}
    workers = {}
    for name, command in commands.items():
        proc = stack.enter_context(subprocess.Popen(command, stdin=subprocess.PIPE,
                                                   stdout=subprocess.PIPE, text=True))
        stack.callback(proc.stdin.close)
        if proc.stdout.readline() != "READY\n":
            raise RuntimeError(f"{name} did not initialize")
        workers[name] = proc
    return workers


def compare(workers, source, order, pair_number, out, program_hash):
    pair = {name: run(workers[name]) for name in order}
    rust, ocaml = pair["rust"], pair["ocaml"]
    if rust[1] != ocaml[1]:
        raise ValueError(f"OS output differs for {source}")
    if pair_number:
        out.writerow([source.name.split(".json")[0], pair_number, order[0], f"{rust[0]:.6f}",
                      f"{ocaml[0]:.6f}", f"{rust[0]/ocaml[0]:.3f}", program_hash])
        sys.stdout.flush()


def stage_input(source, path):
    opener = gzip.open if source.suffix == ".gz" else open
    with opener(source, "rb") as src, path.open("wb") as dst:
        shutil.copyfileobj(src, dst)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ocaml", "rust", "program"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--kind", choices=("os", "virtual-os", "aggregator"), default="os")
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--shuffle-seed", type=int,
                        help="keep both workers alive across inputs, shuffling each traversal with this seed")
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
    if args.shuffle_seed is not None:
        rng = random.Random(args.shuffle_seed)
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            path = Path(temp) / "os-input.json"
            stage_input(args.inputs[0], path)
            workers = workers_for(args, path, stack)
            for i in range(1, args.pairs + 1):
                sources = args.inputs.copy()
                rng.shuffle(sources)
                for source in sources:
                    stage_input(source, path)
                    order = ["rust", "ocaml"]
                    rng.shuffle(order)
                    compare(workers, source, order, i, out, program_hash)
        return
    for source in args.inputs:
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            path = source
            if source.suffix == ".gz":
                path = Path(temp) / "os-input.json"
                stage_input(source, path)
            workers = workers_for(args, path, stack)
            for i in range(args.pairs + 1):
                order = ("rust", "ocaml") if i % 2 else ("ocaml", "rust")
                compare(workers, source, order, i, out, program_hash)


if __name__ == "__main__":
    main()
