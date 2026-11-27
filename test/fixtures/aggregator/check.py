"""Compare the native aggregator with pinned sequencer PIE and blob digests."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path


def compare(binary, program, input_path):
    witness = json.loads(input_path.read_text())
    cases = json.loads(input_path.with_suffix(".sha256.json").read_text())
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "input.json"
        blob = root / "blob.json"
        archive = root / "output.zip"
        for mode, expected in cases.items():
            witness["full_output"] = "full" in mode
            witness["da"] = {"Blob": "blob.json"} if expected["da"] else "CallData"
            source.write_text(json.dumps(witness))
            command = [binary, program, "--aggregator_input", source, "--layout", "all_cairo",
                       "--cairo_pie_output", archive]
            if expected["da"]:
                command.extend(["--aggregator_da_output", blob])
            subprocess.run(command, check=True)
            with zipfile.ZipFile(archive) as z:
                actual = {}
                for member in z.namelist():
                    with z.open(member) as contents:
                        actual[member] = hashlib.file_digest(contents, "sha256").hexdigest()
            if actual != expected["pie"]:
                raise ValueError(f"{input_path.stem} {mode} PIE mismatch")
            if expected["da"] and hashlib.sha256(blob.read_bytes()).hexdigest() != expected["da"]:
                raise ValueError(f"{input_path.stem} {mode} DA mismatch")
            print(f"{input_path.stem} {mode} matches the sequencer")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("program", type=Path)
    args = parser.parse_args()
    for name in ("storage4", "syscalls5"):
        compare(args.binary.resolve(), args.program.resolve(), Path(__file__).with_name(name + ".json"))
