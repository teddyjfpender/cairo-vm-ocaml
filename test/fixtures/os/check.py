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
    parser.add_argument("--virtual-os", action="store_true", help="check the compiled virtual OS")
    parser.add_argument("--only", action="append", help="check this named witness (repeatable)")
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parent
    merged = ("storage-2048", "storage-4096", "syscalls-scaled-32", "storage-8192",
              "syscalls-scaled-64", "sequential-4096", "scattered-4096",
              "deploy-l1-calldata-2048", "deploy-l1-blob-2048")
    cases = ("genesis", "storage", "account", "multi-block", "alternating", "execution-info", "reverted-invoke",
                 "deprecated-calls", "meta-tx", "nested-revert", "syscalls-five-blocks", "syscalls-282", "storage-512",
                  *merged)
    if args.virtual_os:
        cases = ("virtual-message", "virtual-execution-info", "virtual-multicall-16", "virtual-multicall-64")
    if args.only:
        missing = set(args.only) - set(cases)
        if missing:
            parser.error("unknown fixture: " + ", ".join(sorted(missing)))
        cases = args.only
    mode = "--virtual_os_hints" if args.virtual_os else "--os_hints"
    public = json.loads((fixture / "deployment-public-output.json").read_text())
    prime = 2**251 + 17 * 2**192 + 1
    for name in cases:
        expected = json.loads((fixture / f"{name}.sha256.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            source = fixture / f"{name}.json"
            if not source.exists():
                source = Path(directory) / source.name
                source.write_bytes(gzip.decompress((fixture / f"{name}.json.gz").read_bytes()))
            pie = Path(directory) / f"{name}.zip"
            command = [args.binary.resolve(), args.program, mode, source,
                            "--layout", "all_cairo", "--cairo_pie_output", pie]
            if name in merged:
                command.append("--merge_extra_segments")
            if name in public:
                result = subprocess.run([*command, "--print_output"], check=True, capture_output=True)
                lines = result.stdout.splitlines()
                if not lines or lines[0] != b"Program Output:":
                    raise SystemExit(f"{name}: missing public output")
                words = [int(line) % prime for line in lines[1:] if line.strip()]
                digest = hashlib.sha256(b"".join(x.to_bytes(32, "little") for x in words))
                if {"felts": len(words), "sha256": digest.hexdigest()} != public[name]:
                    raise SystemExit(f"{name}: public output differs from Rust")
            else:
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
            if name == "virtual-multicall-16":
                witness = json.loads(source.read_bytes())
                info = witness["os_input"]["os_block_inputs"][0]["tx_execution_infos"][0]
                root = info["execute_call_info"]
                for call in (root, root["inner_calls"][0]):
                    call["tracked_resource"] = "CairoSteps"
                    source.write_text(json.dumps(witness))
                    rejected = subprocess.run(command, capture_output=True, text=True)
                    if rejected.returncode == 0 or "SierraGas" not in rejected.stderr:
                        raise SystemExit("Virtual OS did not enforce Sierra gas tracking")
                    call["tracked_resource"] = "SierraGas"


if __name__ == "__main__":
    main()
