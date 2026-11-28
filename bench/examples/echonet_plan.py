"""Emit a complete-job plan from an authenticated handoff and local tool inventory."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qualify_os_host import digest, require

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("manifest", type=Path)
parser.add_argument("qualification", type=Path)
parser.add_argument("--trusted-sha256", required=True)
parser.add_argument("--sequencer", required=True, type=Path)
for name in ("rust", "oxcairo"):
    parser.add_argument("--" + name, required=True, type=Path)
parser.add_argument("--compiler", action="append", default=[], metavar="ID=PATH")
parser.add_argument("--hardware", required=True)
parser.add_argument("--cache-policy", required=True)
args = parser.parse_args()
root = args.manifest.resolve().parent


def artifact(path):
    return dict(path=str(path.resolve().relative_to(root)), sha256=digest(path))


require(digest(args.manifest) == args.trusted_sha256, "manifest digest mismatch")
manifest = json.loads(args.manifest.read_bytes())
receipt = json.loads(args.qualification.read_bytes())
require(receipt["revision"] == manifest["revision"], "qualification revision mismatch")
require(receipt["manifest_sha256"] == args.trusted_sha256, "qualification manifest mismatch")
# Bind each receipt checkpoint back to the authenticated manifest before pinning the receipt.
cases = {c["number"]: c for c in receipt["cases"]}
require(len(manifest["cases"]) == len(cases) == len(receipt["cases"]), "qualification case count")
for case in manifest["cases"]:
    row = cases.pop(case["number"])
    for field, key in (("source", "source_sha256"), ("witness", "witness_sha256"), ("rust_pie", "sha256")):
        require(case[field]["sha256"] == row[key], f"qualification mismatch for {field}")
compilers = {}
for item in args.compiler:
    name, path = item.split("=", 1)
    require(name and name not in compilers, "duplicate or empty compiler id")
    compilers[name] = artifact(Path(path))
plan = dict(schema=1, chain_id=manifest["chain_id"], hardware=args.hardware,
            cache_policy=args.cache_policy, qualification=artifact(args.qualification),
            qualified_manifest_sha256=args.trusted_sha256,
            cases=[dict(number=c["number"], source=c["source"], witness=c["witness"]) for c in manifest["cases"]],
            pipeline=dict(sequencer=str(args.sequencer.resolve()), program=manifest["program"],
                          rust=artifact(args.rust), oxcairo=artifact(args.oxcairo), compilers=compilers))
print(json.dumps(plan, indent=2))
