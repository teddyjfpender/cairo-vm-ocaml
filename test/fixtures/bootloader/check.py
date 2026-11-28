"""Verify the pinned simple bootloader's nested bitwise PIE in proof mode."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=Path)
parser.add_argument("bootloader", type=Path)
args = parser.parse_args()
fixture = Path(__file__).resolve().parent
expected = json.loads((fixture / "bitwise.sha256.json").read_text())

with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    task = {"type": "CairoPiePath", "program_hash_function": "blake",
            "path": str(fixture.parents[1] / "pie_run/rust4-bitwise.zip")}
    (directory / "tasks.json").write_text(json.dumps({
        "tasks": [task], "single_page": False,
        "fact_topologies_path": str(directory / "ref-topology.json"),
    }))
    output = subprocess.check_output([
        args.binary.resolve(), args.bootloader.resolve(), "--proof_mode",
        "--layout", "starknet_with_keccak", "--bootloader_input", directory / "tasks.json",
        "--print_output", "--trace_file", directory / "trace.bin", "--memory_file", directory / "memory.bin",
    ])
    (directory / "stdout").write_bytes(output)
    for name, digest in expected.items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise SystemExit(f"Rust bootloader mismatch in {name}")
print("Bootloader output, trace, memory and fact topology match Rust")
