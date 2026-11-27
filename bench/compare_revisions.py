#!/usr/bin/env python3
"""Time three secure Cairo VM builds and verify their full outputs after every run."""

import argparse
import filecmp
import itertools
import json
import random
import re
import subprocess
import tempfile
import time
from pathlib import Path


def run(binary, program, directory, tag):
    prefix = directory / tag
    command = [
        str(binary.resolve()), str(program), "--layout", "all_cairo",
        "--stats", "--print_output",
        "--trace_file", str(prefix.with_suffix(".trace")),
        "--memory_file", str(prefix.with_suffix(".mem")),
    ]
    start = time.perf_counter()
    result = subprocess.run(command, capture_output=True, check=True)
    elapsed = time.perf_counter() - start
    match = re.search(rb"\bsteps=(\d+)", result.stderr)
    if match is None:
        raise ValueError(f"Missing Cairo step count from {binary}")
    return elapsed, result.stdout, int(match[1])


def verify(directory, tag, reference, current):
    if current != reference:
        raise ValueError(f"Different stdout or step count from {tag}")
    for suffix in [".trace", ".mem"]:
        left = directory / ("reference" + suffix)
        right = directory / (tag + suffix)
        # Always compare contents. Paths get reused across programs and rounds.
        filecmp.clear_cache()
        if not filecmp.cmp(left, right, shallow=False):
            raise ValueError(f"Different {suffix} from {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path)
    parser.add_argument("previous", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("programs", nargs="+", type=Path)
    parser.add_argument("--rounds", type=int, default=6,
                        help="use a multiple of six to balance binary order")
    parser.add_argument("--seed", type=int, default=2627)
    args = parser.parse_args()
    if args.rounds <= 0 or args.rounds % 6:
        parser.error("--rounds must be a positive multiple of six")
    builds = {"main": args.main, "previous": args.previous, "candidate": args.candidate}
    rng = random.Random(args.seed)
    programs = sorted(args.programs)
    orders = {prog: list(itertools.permutations(builds)) for prog in programs}
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        for batch in range(args.rounds):
            rng.shuffle(programs)
            for prog in programs:
                if batch % 6 == 0:
                    rng.shuffle(orders[prog])
                order = orders[prog][batch % 6]
                times = {}
                for position, name in enumerate(order):
                    tag = "reference" if position == 0 else "current"
                    seconds, stdout, steps = run(builds[name], prog, directory, tag)
                    if position == 0:
                        reference = stdout, steps
                    else:
                        verify(directory, tag, reference, (stdout, steps))
                    times[name] = seconds
                print(json.dumps({"round": batch + 1, "program": prog.stem,
                                  "order": order, "steps": steps, "seconds": times}), flush=True)


if __name__ == "__main__":
    main()
