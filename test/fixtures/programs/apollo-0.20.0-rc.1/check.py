"""Replay historical public witnesses against independent Rust execution and proof receipts."""
import argparse
import gzip
import hashlib
import json
import subprocess
import struct
import tempfile
import zipfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
MODE = {"os": "--os_hints", "virtual_os": "--virtual_os_hints", "aggregator": "--aggregator_input"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_artifacts(directory, proof):
    result = {name: digest((directory / name).read_bytes()) for name in ("trace.bin", "memory.bin")}
    if proof:
        for name in ("air-public.json", "air-private.json"):
            obj = json.loads((directory / name).read_bytes())
            if name == "air-private.json":
                for field, filename in (("trace_path", "trace.bin"), ("memory_path", "memory.bin")):
                    if Path(obj[field]).resolve() != (directory / filename).resolve():
                        raise ValueError(f"Unbound AIR artifact {field}")
                    obj[field] = filename
            result[name] = digest(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode())
    else:
        with zipfile.ZipFile(directory / "pie.zip") as archive:
            result["pie"] = {item: digest(archive.read(item)) for item in archive.namelist()}
    return result


def make_witness(name, case):
    if case["family"] == "aggregator":
        return (HERE / "single-block.json").read_bytes()
    source_name = case.get("source", name)
    source = HERE.parents[1] / "os" / (source_name + ".json")
    data = source.read_bytes() if source.exists() else gzip.decompress(source.with_suffix(".json.gz").read_bytes())
    witness = json.loads(data)
    block, = witness["os_input"]["os_block_inputs"]
    block["block_info"]["starknet_version"] = "0.14.4"
    block["starknet_version_override"] = case.get("on_chain_version")
    block["new_block_hash"] = case["block_hash"]
    if source_name == "genesis":
        witness["os_hints_config"]["full_output"] = True
    return json.dumps(witness).encode()


def run(command, directory):
    return subprocess.run(command, cwd=directory, stdout=subprocess.PIPE, check=True).stdout


def compare(binary, reference, name, case, manifest, root):
    witness = root / "input.json"
    witness.write_bytes(make_witness(name, case))
    family = case["family"]
    for proof in (False, True):
        phase = "proof" if proof else "execution"
        suffix = ".proof.json" if proof else ".json"
        program = root / (family + suffix)
        data = gzip.decompress((HERE / (family + suffix + ".gz")).read_bytes())
        wanted = manifest["programs"][family]["proof_sha256" if proof else "compact_sha256"]
        if digest(data) != wanted:
            raise ValueError(f"{family} {phase} program digest mismatch")
        program.write_bytes(data)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            directory = Path(tmp)
            if reference:
                extra = ["--proof-program", program] if proof else []
                output = run([reference / "os_traced", family.replace("_", "-"), witness, directory, *extra], directory)
                if not proof:
                    words = run([reference / (family + "_reference"), witness, directory / "pie.zip"], directory)
                    signed = output.splitlines()[1:]
                    prime = 2**251 + 17 * 2**192 + 1
                    if [int(w) % prime for w in signed] != [int(w, 16) for w in words.splitlines()]:
                        raise ValueError(f"{name} stock API and traced output differ")
            else:
                extra = ["--proof_mode", "--air_public_input", "air-public.json", "--air_private_input",
                         "air-private.json"] if proof else ["--cairo_pie_output", "pie.zip"]
                output = run([binary, program, MODE[family], witness, "--layout", "all_cairo", "--print_output",
                              "--trace_file", "trace.bin", "--memory_file", "memory.bin", *extra], directory)
            actual = read_artifacts(directory, proof)
            actual["stdout"] = digest(output)
            if actual != case[phase]:
                differing = [k for k in actual if actual[k] != case[phase].get(k)]
                raise ValueError(f"{name} {phase} mismatch in {differing}")
            print(f"{name} {phase} matches the pinned Rust artifacts")


def check_debug_gas(binary, reference, case, root):
    # This fixture's execution gas prediction comes from the later protocol.
    # The pinned runner gates the diagnostic on debug_mode, while Cairo's
    # execution constraints and the syscall-end-pointer checks always run.
    witness = json.loads(make_witness("account", case))
    witness["os_hints_config"]["debug_mode"] = True
    path = root / "debug-input.json"
    path.write_text(json.dumps(witness))
    if reference:
        command = [reference / "os_reference", path]
        expected = b"Predicted gas costs are inconsistent"
    else:
        command = [binary, root / "os.json", "--layout", "all_cairo", "--os_hints", path]
        expected = b"Inconsistent predicted contract gas"
    result = subprocess.run(command, cwd=root, capture_output=True)
    if result.returncode == 0 or expected not in result.stderr:
        raise ValueError("Expected an explicit debug gas rejection")
    print("Debug mode rejects the incompatible predicted gas")


def check_standard_hints(binary, manifest, root):
    data = gzip.decompress((HERE / "standard-hints.json.gz").read_bytes())
    expected = manifest["standard_hints"]
    if digest(data) != expected["program_sha256"]:
        raise ValueError("Wrong standard hint program")
    program = root / "standard-hints.json"
    program.write_bytes(data)
    run([binary, program, "--layout", "all_cairo", "--trace_file", "trace.bin",
         "--memory_file", "memory.bin"], root)
    trace = (root / "trace.bin").read_bytes()
    # The runnable program is segment zero, relocated to address 1.
    pcs = {pc - 1 for _, _, pc in struct.iter_unpack("<QQQ", trace)}
    hints = json.loads(data)["hints"]
    visited = {hint["code"] for pc, group in hints.items() if int(pc) in pcs for hint in group}
    all_hints = {hint["code"] for group in hints.values() for hint in group}
    if visited != all_hints or len(visited) != expected["hint_bodies"]:
        raise ValueError("Standard hint coverage differs")
    if digest(trace) != expected["trace_sha256"] or digest((root / "memory.bin").read_bytes()) != expected["memory_sha256"]:
        raise ValueError("Standard hint artifacts differ from Rust")
    print(f"Executed all {len(visited)} standard hint bodies with matching trace and memory")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--binary", type=Path, help="installed native CLI")
    group.add_argument("--prepare", type=Path, help="write programs and witnesses into a new directory")
    group.add_argument("--reference-dir", type=Path, help="pinned sequencer's built examples")
    parser.add_argument("--stock-cli", type=Path, help="cairo-vm 3.2.0 CLI for standard hints with --reference-dir")
    args = parser.parse_args()
    cases = json.loads((HERE / "cases.json").read_bytes())
    manifest = json.loads((HERE / "manifest.json").read_bytes())
    if args.prepare:
        args.prepare.mkdir(parents=True)
        for name, case in cases.items():
            (args.prepare / (name + ".json")).write_bytes(make_witness(name, case))
        for family in MODE:
            for suffix in (".json", ".proof.json"):
                encoded = HERE / (family + suffix + ".gz")
                (args.prepare / (family + suffix)).write_bytes(gzip.decompress(encoded.read_bytes()))
        raise SystemExit(0)
    with tempfile.TemporaryDirectory() as tmp:
        if args.binary or args.stock_cli:
            check_standard_hints((args.binary or args.stock_cli).resolve(), manifest, Path(tmp))
        for name, case in cases.items():
            compare(args.binary and args.binary.resolve(), args.reference_dir and args.reference_dir.resolve(),
                    name, case, manifest, Path(tmp))
        check_debug_gas(args.binary and args.binary.resolve(), args.reference_dir and args.reference_dir.resolve(),
                        cases["account"], Path(tmp))
