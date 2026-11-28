"""Check pinned reference bytes across independent process workers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import json
import resource
import signal
from pathlib import Path
import subprocess
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent / "fixtures"


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def unpack(source, dest):
    if source.suffix != ".gz":
        return source
    with gzip.open(source, "rb") as stream:
        dest.write_bytes(stream.read())
    return dest


def check(case, expected, cli, encrypted):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        program = unpack(FIXTURES / "programs" / (expected["program"] + ".json.gz"), root / "program")
        witness = unpack(FIXTURES / expected["witness"], root / "witness")
        archive = root / "output.zip"
        if expected["flag"] == "synthetic-entropy":
            args = [encrypted, program, witness, archive, root / "trace", root / "memory"]
        else:
            args = [cli, program, expected["flag"], witness, "--layout", "all_cairo", "--pie_profile",
                    "rust-3.2", "--cairo_pie_output", archive, "--trace_file", root / "trace",
                    "--memory_file", root / "memory"]
        subprocess.run(args, check=True, capture_output=True, timeout=120)
        with zipfile.ZipFile(archive) as actual:
            if actual.namelist() != list(expected["members"]):
                raise ValueError(f"{case}: ZIP member names or order differ")
            for name, value in expected["members"].items():
                if hashlib.sha256(actual.read(name)).hexdigest() != value:
                    raise ValueError(f"{case}: uncompressed {name} differs")
        if archive.stat().st_size != expected["bytes"] or digest(archive) != expected["archive"]:
            raise ValueError(f"{case}: member contents match but complete ZIP container differs")
        for item in ("trace", "memory"):
            if item in expected and digest(root / item) != expected[item]:
                raise ValueError(f"{case}: relocated {item} differs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    parser.add_argument("encrypted_driver", type=Path)
    args = parser.parse_args()
    # Force write/flush to report EFBIG without delivering a signal to other
    # processes. The OCaml helper distinguishes Unix.Unix_error from Vm_error.
    def output_limit():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
    with tempfile.TemporaryDirectory() as tmp:
        helper = args.encrypted_driver.resolve().with_name("errno_check.exe")
        subprocess.run([helper, Path(tmp) / "rejected.zip"], check=True, preexec_fn=output_limit)
    cases = json.loads((HERE / "references.json").read_text())
    for workers in (1, 2):
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = [pool.submit(check, name, expected, args.cli.resolve(), args.encrypted_driver.resolve())
                       for name, expected in cases.items()]
            for result in results:
                result.result()
        print(f"{len(cases)} exact archives matched, {workers} process workers")


if __name__ == "__main__":
    main()
