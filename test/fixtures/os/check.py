"""Compare a native genesis run against the upstream sequencer's saved PIE member hashes."""
import argparse
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
    expected = json.loads((fixture / "genesis.sha256.json").read_text())
    with tempfile.TemporaryDirectory() as directory:
        pie = Path(directory) / "genesis.zip"
        subprocess.run([args.binary.resolve(), args.program, "--os_hints", fixture / "genesis.json",
                        "--layout", "all_cairo", "--cairo_pie_output", pie], check=True)
        with zipfile.ZipFile(pie) as z:
            hashes = {name: hashlib.sha256(z.read(name)).hexdigest() for name in z.namelist()}
        if hashes != expected:
            raise SystemExit("Sequencer PIE member mismatch")
        print("Native genesis matches all sequencer PIE members")


if __name__ == "__main__":
    main()
