"""Compare native OS runs against the upstream sequencer's saved PIE member hashes."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("program", type=Path)
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parent
    for name in ("genesis", "storage", "account", "alternating", "execution-info", "reverted-invoke",
                 "syscalls-five-blocks", "storage-512", "storage-2048"):
        expected = json.loads((fixture / f"{name}.sha256.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            source = fixture / f"{name}.json"
            if not source.exists():
                source = Path(directory) / source.name
                source.write_bytes(gzip.decompress((fixture / f"{name}.json.gz").read_bytes()))
            pie = Path(directory) / f"{name}.zip"
            command = [args.binary.resolve(), args.program, "--os_hints", source,
                            "--layout", "all_cairo", "--cairo_pie_output", pie]
            if name == "storage-2048":
                command.append("--merge_extra_segments")
            subprocess.run(command, check=True)
            with zipfile.ZipFile(pie) as z:
                hashes = {}
                for member in z.namelist():
                    with z.open(member) as stream:
                        digest = hashlib.sha256()
                        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(chunk)
                        hashes[member] = digest.hexdigest()
            if hashes != expected:
                raise SystemExit(f"{name}: sequencer PIE member mismatch")
            print(f"Native {name} matches all sequencer PIE members")


if __name__ == "__main__":
    main()
