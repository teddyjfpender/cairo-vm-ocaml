"""Pair two native OS executables on the full compiler and pinned 70 witnesses."""
import argparse
import csv
import hashlib
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys
import tempfile
import time


def measure(binary, program, witness):
    with tempfile.TemporaryFile() as stdout:
        start = time.monotonic()
        process = subprocess.Popen([binary, program, "--layout", "all_cairo", "--print_output",
                                    "--os_hints", witness], stdout=stdout)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.monotonic() - start
        process.returncode = os.waitstatus_to_exitcode(status)
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, process.args)
        stdout.seek(0)
        rss = usage.ru_maxrss if sys.platform == "darwin" else 1024 * usage.ru_maxrss
        return stdout.read(), elapsed, usage.ru_utime + usage.ru_stime, rss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("base", "candidate", "program", "witness_directory", "receipt"):
        parser.add_argument(key, type=Path)
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    with (directory / "scenarios.csv").open() as stream:
        oracle = {row["case"]: row["digest"] for row in csv.DictReader(stream)}
    with (directory.parent / "witnesses.csv").open() as stream:
        hashes = {row["case"]: row["sha256"] for row in csv.DictReader(stream)}
    if hashlib.sha256(args.program.read_bytes()).hexdigest() != (
            "2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded"):
        raise ValueError("unexpected raw compiler input")
    cases = sorted(oracle)
    for case in cases:
        if hashlib.sha256((args.witness_directory / (case + ".json")).read_bytes()).hexdigest() != hashes[case]:
            raise ValueError("unexpected witness " + case)
    rng = random.Random(3108)
    prime = (1 << 251) + 17 * (1 << 192) + 1
    binaries = [args.base.resolve(), args.candidate.resolve()]
    by_case = {case: [] for case in cases}
    with args.receipt.open("w") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(["case", "round", "base_s", "trial_s", "base_cpu", "trial_cpu",
                         "base_rss_bytes", "trial_rss_bytes", "digest", "load"])
        for turn in range(9):
            rng.shuffle(cases)
            for index, case in enumerate(cases):
                order = [0, 1] if (index + turn) % 2 == 0 else [1, 0]
                witness = args.witness_directory / (case + ".json")
                result = {i: measure(binaries[i], args.program, witness) for i in order}
                a, b = result[0], result[1]
                words = (int(line, 0) % prime for line in a[0].splitlines()
                         if line.strip() and not line.startswith(b"Program"))
                digest = hashlib.sha256(b"".join(x.to_bytes(32, "big") for x in words)).hexdigest()
                if a[0] != b[0] or digest != oracle[case]:
                    raise ValueError("public output mismatch on " + case)
                writer.writerow([case, turn + 1, a[1], b[1], a[2], b[2], a[3], b[3], digest, os.getloadavg()[0]])
                by_case[case].append(a[1] / b[1])
    print(f"Median case speedup {statistics.median(map(statistics.median, by_case.values())):.3f}x")


if __name__ == "__main__":
    main()
