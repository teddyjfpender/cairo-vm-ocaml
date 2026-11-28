"""Time sequential, alternating OS PIE replays and compare their artifacts."""
import argparse
import csv
import filecmp
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from zipfile import ZipFile


def same_pie(left, right):
    with ZipFile(left) as a, ZipFile(right) as b:
        if sorted(a.namelist()) != sorted(b.namelist()):
            return False
        for name in a.namelist():
            with a.open(name) as src, b.open(name) as dst:
                while True:
                    data = src.read(1 << 20)
                    if data != dst.read(1 << 20):
                        return False
                    if not data:
                        break
    return True


def compare(rust, ocaml, pie, root, repeat, full, rows):
    env = os.environ.copy()
    env.pop("CAIRO_VM_RUST_CLI", None)
    env.pop("CAIRO_VM_DELEGATED", None)
    for pair in range(repeat):
        times = {}
        order = [("rust", rust), ("ocaml", ocaml)]
        for label, binary in (order if pair % 2 == 0 else reversed(order)):
            cmd = [binary, pie, "--run_from_cairo_pie", "--layout", "all_cairo", "--print_output"]
            if full:
                for flag, suffix in (("--trace_file", "trace"), ("--memory_file", "memory"),
                                     ("--cairo_pie_output", "zip")):
                    cmd.extend([flag, root / f"{label}.{suffix}"])
            with (root / f"{label}.stdout").open("wb") as out:
                start = time.perf_counter()
                subprocess.run(cmd, stdout=out, env=env, check=True)
                times[label] = time.perf_counter() - start
        for suffix in (("stdout", "trace", "memory", "zip") if full else ("stdout",)):
            a, b = (root / f"{label}.{suffix}" for label in ("rust", "ocaml"))
            match = same_pie(a, b) if suffix == "zip" else filecmp.cmp(a, b, shallow=False)
            if not match:
                raise ValueError(f"{pie}: {suffix} differs in pair {pair + 1}")
            a.unlink()
            b.unlink()
        rows.writerow([pie.name, "full" if full else "exec", pair + 1,
                       f'{times["rust"]:.6f}', f'{times["ocaml"]:.6f}',
                       f'{times["rust"] / times["ocaml"]:.3f}'])
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust", type=Path)
    parser.add_argument("ocaml", type=Path)
    parser.add_argument("pies", type=Path, nargs="+")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--full", action="store_true", help="also produce and compare trace, memory and output PIE")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    rows = csv.writer(sys.stdout, lineterminator="\n")
    rows.writerow(["pie", "mode", "pair", "rust_s", "ocaml_s", "speedup"])
    with tempfile.TemporaryDirectory() as directory:
        for pie in args.pies:
            compare(args.rust.resolve(), args.ocaml.resolve(), pie, Path(directory),
                    args.repeat, args.full, rows)


if __name__ == "__main__":
    main()
