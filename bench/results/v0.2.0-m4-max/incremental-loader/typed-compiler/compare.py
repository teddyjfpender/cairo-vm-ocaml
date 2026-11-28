"""Reproduce the regular-release 70-scenario loader comparison."""
import argparse
import csv
import hashlib
import os
from pathlib import Path
import random
import resource
import statistics
import subprocess
import time


def output_digest(output):
    prime = (1 << 251) + 17 * (1 << 192) + 1
    words = (int(line, 0) % prime for line in output.splitlines()
             if line.strip() and not line.startswith(b"Program"))
    return hashlib.sha256(b"".join(word.to_bytes(32, "big") for word in words)).hexdigest()


def measure(executable, program, witness):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    output = subprocess.check_output([executable, program, "--layout", "all_cairo",
                                      "--print_output", "--os_hints", witness])
    elapsed = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return output, elapsed, after.ru_utime - before.ru_utime, after.ru_stime - before.ru_stime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base", "candidate", "program", "witness_directory", "receipt"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    with (root / "scenarios.csv").open() as stream:
        oracle = {row["case"]: row["public_output_sha256"] for row in csv.DictReader(stream)}
    with (root.parent / "witnesses.csv").open() as stream:
        hashes = {row["case"]: row["sha256"] for row in csv.DictReader(stream)}
    witnesses = {case: args.witness_directory / (case + ".json") for case in oracle}
    for case, path in witnesses.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[case]:
            raise ValueError(f"unexpected witness bytes for {case}")
    if hashlib.sha256(args.program.read_bytes()).hexdigest() != (
            "2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded"):
        raise ValueError("unexpected program bytes")
    binaries = {"base": args.base.resolve(), "candidate": args.candidate.resolve()}
    rng = random.Random(17831)
    values = {case: [] for case in oracle}
    with args.receipt.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["case", "round", "first", "base_s", "candidate_s", "public_output_sha256",
                         "base_user_s", "base_system_s", "candidate_user_s", "candidate_system_s",
                         "round_load_1m"])
        for turn in range(9):
            cases = sorted(oracle)
            rng.shuffle(cases)
            load = os.getloadavg()[0]
            for index, case in enumerate(cases):
                order = ("base", "candidate") if (index + turn) % 2 == 0 else ("candidate", "base")
                result = {name: measure(binaries[name], args.program, witnesses[case]) for name in order}
                base, candidate = result["base"], result["candidate"]
                digest = output_digest(base[0])
                if base[0] != candidate[0] or digest != oracle[case]:
                    raise ValueError(f"public output mismatch for {case}")
                writer.writerow([case, turn + 1, order[0], base[1], candidate[1], digest,
                                 *base[2:], *candidate[2:], load])
                values[case].append(base[1] / candidate[1])
    print(f"Median case speedup {statistics.median(map(statistics.median, values.values())):.3f}x")


if __name__ == "__main__":
    main()
