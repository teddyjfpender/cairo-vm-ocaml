"""Time native OS execution from block inputs using a pinned run_os_stateless reference."""
import argparse
import csv
import gzip
import hashlib
import mmap
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import zipfile


PRIME = 2**251 + 17 * 2**192 + 1


def run(command, max_rss_mib):
    env = os.environ.copy()
    env.pop("CAIRO_VM_RUST_CLI", None)
    finished = threading.Event()
    peak_kib = 0

    def monitor(process):
        nonlocal peak_kib
        while not finished.wait(0.075):
            sample = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)],
                                    text=True, capture_output=True)
            rss = sample.stdout.strip()
            if rss.isdecimal():
                peak_kib = max(peak_kib, int(rss))
                if peak_kib > max_rss_mib * 1024:
                    process.terminate()
                    return

    start = time.perf_counter()
    with subprocess.Popen(command, stdout=subprocess.PIPE, text=True, env=env) as process:
        watcher = threading.Thread(target=monitor, args=(process,)) if max_rss_mib else None
        if watcher:
            watcher.start()
        try:
            output, _ = process.communicate()
            elapsed = time.perf_counter() - start
        finally:
            finished.set()
            if watcher:
                watcher.join()
        if max_rss_mib and peak_kib > max_rss_mib * 1024:
            raise RuntimeError(f"{command[0]} exceeded {max_rss_mib} MiB RSS")
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command)
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


def embedded_program_digest(binary, program):
    """The pinned sequencer embeds the complete compiler JSON with include_bytes!."""
    with program.open("rb") as source, binary.open("rb") as executable:
        if source.seek(0, os.SEEK_END) == 0:
            raise ValueError("empty compiler program")
        with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data, \
             mmap.mmap(executable.fileno(), 0, access=mmap.ACCESS_READ) as image:
            prefix = data[:1024]
            start = image.find(prefix)
            chunk_size = 1024 * 1024
            while start >= 0:
                if start + len(data) <= len(image) and all(
                    image[start + i:start + min(i + chunk_size, len(data))] == data[i:i + chunk_size]
                    for i in range(0, len(data), chunk_size)
                ):
                    return hashlib.sha256(data).hexdigest()
                start = image.find(prefix, start+1)
    raise ValueError("compiler JSON does not occur byte-for-byte in the Rust reference binary")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ocaml", "rust"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--program", type=Path, required=True, help="compiler JSON from the sequencer build output")
    parser.add_argument("--prepared-program", type=Path, help="explicitly compare a transformed OCaml input with the embedded Rust program")
    parser.add_argument("--kind", choices=("os", "virtual-os", "aggregator"), default="os")
    parser.add_argument("--mode", choices=("both", "output", "pie"), default="both")
    parser.add_argument("--merge-extra-segments", action="store_true")
    parser.add_argument("--max-rss-mib", type=int, help="stop an individual timed child above its sampled RSS limit")
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()
    if args.max_rss_mib is not None and args.max_rss_mib < 1:
        parser.error("--max-rss-mib must be positive")
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    try:
        reference_hash = embedded_program_digest(args.rust, args.program)
    except ValueError as error:
        parser.error(str(error))
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(["case", "mode", "pair", "first", "rust_s", "ocaml_s", "speedup", "program_mode", "rust_program_sha256", "ocaml_program_sha256"])
    with tempfile.TemporaryDirectory() as directory:
        program = args.prepared_program or args.program
        candidate_hash = reference_hash
        if args.prepared_program:
            with program.open("rb") as stream:
                candidate_hash = hashlib.file_digest(stream, "sha256").hexdigest()
        identity = ["prepared" if args.prepared_program else "identical", reference_hash, candidate_hash]
        archives = {vm: Path(directory) / f"{vm}.zip" for vm in ("ocaml", "rust")}
        for path in args.inputs:
            source = path
            if path.suffix == ".gz":
                source = Path(directory) / "os-input.json"
                with gzip.open(path, "rb") as compressed, source.open("wb") as uncompressed:
                    shutil.copyfileobj(compressed, uncompressed)
            flag = {"os": "--os_hints", "virtual-os": "--virtual_os_hints",
                    "aggregator": "--aggregator_input"}[args.kind]
            reference_args = [] if args.kind == "os" else ["--" + args.kind]
            for mode in (("pie", "output") if args.mode == "both" else (args.mode,)):
                commands = {"ocaml": [args.ocaml.resolve(), program, "--layout", "all_cairo",
                                      flag, source, "--print_output"],
                            "rust": [args.rust.resolve(), *reference_args, source]}
                if mode == "pie":
                    commands["ocaml"] += ["--cairo_pie_output", archives["ocaml"]]
                    commands["rust"].append(archives["rust"])
                    if args.merge_extra_segments:
                        commands["ocaml"].append("--merge_extra_segments")
                        commands["rust"].append("--merge-extra-segments")
                for i in range(args.pairs):
                    order = ("rust", "ocaml") if i % 2 == 0 else ("ocaml", "rust")
                    result = {vm: run(commands[vm], args.max_rss_mib) for vm in order}
                    (r, rf), (o, of) = result["rust"], result["ocaml"]
                    if rf != of:
                        raise ValueError("OS output differs")
                    if mode == "pie":
                        compare_archive(archives["rust"], archives["ocaml"])
                    writer.writerow([path.name.split(".json")[0], mode, i + 1, order[0],
                                     f"{r:.6f}", f"{o:.6f}", f"{r / o:.3f}", *identity])
                    sys.stdout.flush()


if __name__ == "__main__":
    main()
