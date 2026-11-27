"""Compare release builds of cairo-vm-cli and cairo-vm-ocaml on compiled programs."""
import argparse
import csv
import filecmp
import os
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust", type=Path)
    parser.add_argument("ocaml", type=Path)
    parser.add_argument("programs", nargs="+", type=Path)
    parser.add_argument("--runs", type=int, default=4)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()
    if args.runs < 2 or args.runs % 2:
        parser.error("--runs must be positive and even")
    rng = random.Random(267)
    results = csv.writer(sys.stdout, lineterminator="\n")
    results.writerow(["round", "program", "first", "rust_seconds", "ocaml_seconds"])
    binaries = {"rust": args.rust.resolve(), "ocaml": args.ocaml.resolve()}
    native_env = os.environ.copy()
    native_env.pop("CAIRO_VM_RUST_CLI", None)
    programs = sorted(args.programs)
    first = {prog: rng.choice(list(binaries)) for prog in programs}
    with tempfile.TemporaryDirectory() as directory:
        for i in range(args.runs):
            rng.shuffle(programs)
            for prog in programs:
                order = sorted(binaries, key=lambda tag: tag != first[prog], reverse=bool(i % 2))
                times, outputs = {}, {}
                for tag in order:
                    cmd = [binaries[tag], prog, "--layout", "all_cairo", "--print_output"]
                    if args.trace:
                        for option in ("trace", "memory"):
                            cmd.extend(["--" + option + "_file", Path(directory) / (tag + option)])
                    start = time.perf_counter()
                    result = subprocess.run(cmd, stdout=subprocess.PIPE, check=True, env=native_env)
                    times[tag] = time.perf_counter() - start
                    outputs[tag] = result.stdout
                if outputs["rust"] != outputs["ocaml"]:
                    raise ValueError(f"{prog}: different stdout")
                if args.trace:
                    filecmp.clear_cache()
                    for option in ("trace", "memory"):
                        paths = [Path(directory) / (tag + option) for tag in binaries]
                        if not filecmp.cmp(*paths, shallow=False):
                            raise ValueError(f"{prog}: different {option} bytes")
                results.writerow([i + 1, prog.stem, order[0], times["rust"], times["ocaml"]])
                sys.stdout.flush()


if __name__ == "__main__":
    main()
