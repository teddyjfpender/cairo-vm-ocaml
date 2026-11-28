"""Compare successful pinned Rust and ABI exports. Exit nonzero on any mismatch.
Each directory must contain trace.bin, memory.bin and pie.zip.
Usage: python3 compare.py RUST_DIR ABI_DIR
"""
import argparse
import json
import sys
import zipfile
from pathlib import Path

MEMBERS = {"version.json", "metadata.json", "memory.bin", "additional_data.json",
           "execution_resources.json"}
CHUNK = 1 << 20


def first_diff(left, right):
    offset = 0
    while True:
        a, b = left.read(CHUNK), right.read(CHUNK)
        if a != b:
            return offset + next((i for i, (x, y) in enumerate(zip(a, b)) if x != y),
                                 min(len(a), len(b)))
        if not a:
            return None
        offset += len(a)


def compare(reference, candidate):
    issues = []
    for name, width in [("trace.bin", 24), ("memory.bin", 40)]:
        lhs, rhs = reference / name, candidate / name
        if lhs.stat().st_size % width or rhs.stat().st_size % width:
            issues.append(f"{name} contains a partial record")
        with lhs.open("rb") as a, rhs.open("rb") as b:
            off = first_diff(a, b)
            if off is not None:
                issues.append(f"{name} first difference at byte {off}, record {off // width}")
    with zipfile.ZipFile(reference / "pie.zip") as left, zipfile.ZipFile(candidate / "pie.zip") as right:
        for z in (left, right):
            if sorted(z.namelist()) != sorted(MEMBERS):
                raise ValueError(f"unexpected or duplicate PIE members in {z.filename}")
        for name in sorted(MEMBERS):
            with left.open(name) as a, right.open(name) as b:
                off = first_diff(a, b)
            if off is not None:
                detail = ""
                if name.endswith(".json"):
                    equal = json.loads(left.read(name)) == json.loads(right.read(name))
                    detail = f", parsed JSON equal={equal}"
                issues.append(f"PIE {name} first difference at byte {off}{detail}")
        for folder, z in [(reference, left), (candidate, right)]:
            n = json.loads(z.read("execution_resources.json"))["n_steps"]
            if (folder / "trace.bin").stat().st_size != 24 * n:
                issues.append(f"{folder} trace row count differs from PIE n_steps")
    return issues


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    try:
        differences = compare(args.reference, args.candidate)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        sys.exit(str(exc))
    if differences:
        sys.exit("\n".join(differences))
    print("Identical trace, relocated memory and five decompressed PIE members")
