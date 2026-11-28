#!/usr/bin/env python3
"""Run the extracted CLI, worker and embedding library against the sequencer's genesis fixture."""

import argparse
import ctypes
import gzip
import hashlib
import json
import os
import runpy
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    archive = parser.parse_args().archive.resolve()
    name = archive.name.removesuffix(".tar.gz")
    expected_sha = archive.with_suffix(".gz.sha256").read_text().split()[0]
    with archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected_sha:
            raise SystemExit("release archive checksum mismatch")

    fixtures = Path(__file__).resolve().parents[1] / "test" / "fixtures"
    witness = fixtures / "os" / "genesis.json"
    expected = json.loads(witness.with_suffix(".sha256.json").read_text())
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        with tarfile.open(archive) as tar:
            tar.extractall(work, filter="data")
        package = work / name
        program = work / "compiled OS.json"
        program.write_bytes(gzip.decompress((fixtures / "programs/starknet-os-training.json.gz").read_bytes()))
        for script in ("os_host.py", "os_host_recovery.py"):
            subprocess.run([sys.executable, str(fixtures.parent / script), str(package / "oxcairo-os-host"),
                            str(program), str(witness)], check=True)
        apollo = fixtures / "programs/apollo-0.20.0-rc.1"
        make_witness = runpy.run_path(str(apollo / "check.py"))["make_witness"]
        genesis = json.loads((apollo / "cases.json").read_bytes())["genesis"]
        compiled = work / "apollo-os.json"
        compiled.write_bytes(gzip.decompress((apollo / "os.json.gz").read_bytes()))
        historical = work / "apollo-genesis.json"
        historical.write_bytes(make_witness("genesis", genesis))
        job = dict(schema=1, revision="1860b9850b5c51858c50c0f5038933e49f932eef", program=str(compiled),
                   witness=str(historical), output=str(work / "standard.zip"))
        result = subprocess.check_output([package / "oxcairo-os-host", "v1"], input=json.dumps(job).encode())
        # Pinned sequencer os_reference WITNESS.json EXPECTED.zip --merge-extra-segments
        expected_zip = "b78c75c541cdd948d1d7603d41103aa3f6ceb8ae505630a4f3cbe3e791f47bd7"
        if json.loads(result)["sha256"] != expected_zip or hashlib.sha256(Path(job["output"]).read_bytes()).hexdigest() != expected_zip:
            raise SystemExit("installed Apollo host output differs from the complete merged Rust archive")
        env = {"HOME": directory, "PATH": "", "LC_ALL": "C"}
        pie = work / "genesis.zip"
        output = subprocess.check_output(
            [package / "cairo-vm-cli", program, "--layout", "all_cairo", "--os_hints", witness,
             "--print_output", "--cairo_pie_output", pie], cwd=work, env=env,
        )
        worker_output = subprocess.check_output(
            [package / "oxcairo-os-worker", program, witness], input=b"RUN\nRUN\n", cwd=work, env=env,
        )
        header, _, words = output.partition(b"\n")
        if header != b"Program Output:" or not words:
            raise SystemExit("missing genesis public output")
        if worker_output != b"READY\n" + (words + b"DONE\n") * 2:
            raise SystemExit("packaged worker output differs from CLI")

        library = ctypes.CDLL(str(package / "lib" / "oxcairo.so"))
        replay = library.oxcairo_replay_v1
        replay.argtypes = [ctypes.c_char_p] * 5 + [ctypes.POINTER(ctypes.c_char), ctypes.c_size_t]
        replay.restype = ctypes.c_int
        error = ctypes.create_string_buffer(512)
        rebuilt = work / "replayed.zip"
        if replay(os.fsencode(pie), None, None, None, os.fsencode(rebuilt), error, len(error)):
            raise SystemExit(f"packaged library replay failed: {error.value!r}")
        for product in (pie, rebuilt):
            with zipfile.ZipFile(product) as z:
                hashes = {}
                for member in z.infolist():
                    with z.open(member) as src:
                        hashes[member.filename] = hashlib.file_digest(src, "sha256").hexdigest()
                if len(z.infolist()) != len(expected) or hashes != expected:
                    raise SystemExit(f"{product.name} differs from the Rust genesis PIE")
    print("Packaged CLI, worker and replay library passed the genesis check")


if __name__ == "__main__":
    main()
