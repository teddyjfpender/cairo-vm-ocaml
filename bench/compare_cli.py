"""Compare release builds of cairo-vm-cli and cairo-vm-ocaml on compiled programs."""
import argparse
import csv
from collections import defaultdict
import filecmp
import os
import random
import subprocess
import statistics
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
    parser.add_argument("--min-suite-speedup", type=float, metavar="RATIO",
                        help="fail if the ratio of summed per-program median times is below RATIO")
    args = parser.parse_args()
    if args.runs < 2 or args.runs % 2:
        parser.error("--runs must be positive and even")
    if args.min_suite_speedup is not None and not args.min_suite_speedup > 0:
        parser.error("--min-suite-speedup must be positive")
    samples = defaultdict(lambda: defaultdict(list))
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
                for tag, seconds in times.items():
                    samples[prog][tag].append(seconds)
                results.writerow([i + 1, prog.stem, order[0], times["rust"], times["ocaml"]])
                sys.stdout.flush()

    if args.min_suite_speedup is not None:
        totals = {tag: sum(statistics.median(pair[tag]) for pair in samples.values()) for tag in binaries}
        speedup = totals["rust"] / totals["ocaml"]
        print(f"Suite speedup {speedup:.3f}x (required {args.min_suite_speedup:g}x)", file=sys.stderr)
        if speedup < args.min_suite_speedup:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
