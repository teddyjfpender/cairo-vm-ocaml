"""Compare decrypted native and sequencer OS outputs, including blob commitment checks."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

PRIME = 2**251 + 17*2**192 + 1
CASES = {"state-blob": "3,1", "state-calldata": "3,1", "one-block": "1,2", "three-block": "1,2"}


def check(vm, reference, program, fixture, keys):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        witness = root / "input.json"
        witness.write_bytes(gzip.decompress(fixture.read_bytes()))
        expected = json.loads(subprocess.check_output([reference, keys, "run", witness]))
        for _ in range(2):
            da = root / "da.json"
            out = subprocess.check_output(
                [vm, program, "--layout", "all_cairo", "--os_hints", witness,
                 "--os_da_output", da, "--print_output"], text=True
            )
            public_words = root / "public.txt"
            public_words.write_text("".join(
                f"{int(line) % PRIME:#x}\n" for line in out.splitlines() if line != "Program Output:"
            ))
            coefficients = root / "coefficients.txt"
            coefficients.write_text("".join(word + "\n" for word in (json.loads(da.read_text()) or [])))
            actual = json.loads(subprocess.check_output([reference, keys, "check", public_words, coefficients]))
            if actual != expected:
                raise ValueError(f"decrypted state or common OS output differs for {fixture.name}")
        canonical = json.dumps(expected, sort_keys=True, separators=(",", ":")).encode()
        print(f"{fixture.name} two native runs matched the sequencer, SHA-256 {hashlib.sha256(canonical).hexdigest()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("vm", "reference", "program"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    for name, keys in CASES.items():
        check(args.vm.resolve(), args.reference.resolve(), args.program.resolve(),
              Path(__file__).with_name(name + ".json.gz"), keys)
