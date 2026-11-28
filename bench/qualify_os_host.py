#!/usr/bin/env python3
"""Check an externally authenticated mainnet sample against an installed OS host."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

CATEGORIES = {"cairo0-account", "declare", "revert", "large-storage"}
FELT_PRIME = (1 << 251) + 17 * (1 << 192) + 1


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def felt(value):
    require(isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]+", value), "invalid hexadecimal felt")
    number = int(value, 16)
    require(number < FELT_PRIME, "felt outside the Stark field")
    return number


def asset(root, entry):
    path = (root / entry["path"]).resolve()
    require(path.is_relative_to(root) and path.is_file(), "asset must be a regular file in the handoff")
    require(digest(path) == entry["sha256"], "asset digest mismatch for " + str(entry["path"]))
    return path


def qualify(manifest, trusted_digest, host):
    require(digest(manifest) == trusted_digest, "handoff manifest differs from its trusted digest")
    root = manifest.parent.resolve()
    data = json.loads(manifest.read_bytes())
    require(data["schema"] == 1 and data["chain_id"] == "SN_MAIN", "expected mainnet handoff schema 1")
    require(data["cairo_vm"] == "3.2.0", "expected Rust VM 3.2.0")
    require(re.fullmatch("[0-9a-f]{40}", data["revision"]), "missing source revision")
    program = asset(root, data["program"])
    blocks = set()
    categories = set()
    compiler_versions = set()
    results = []
    with tempfile.TemporaryDirectory() as directory:
        for case in data["cases"]:
            number = case["number"]
            require(type(number) is int and number >= 0 and number not in blocks, "invalid or repeated block")
            blocks.add(number)
            ids = set(case["categories"])
            require(ids and ids <= CATEGORIES, "unknown sample category")
            categories |= ids
            if "declare" in ids:
                versions = case["declared_compiler_versions"]
                require(isinstance(versions, list) and versions and
                        all(isinstance(v, str) and v.strip() for v in versions), "missing declared compiler identities")
                compiler_versions.update(versions)
            receipt = json.loads(asset(root, case["fold_receipt"]).read_bytes())
            require(receipt["chain_id"] == "SN_MAIN" and receipt["number"] == number, "state-fold receipt identity")
            require(felt(receipt["block_hash"]) == felt(case["block_hash"]), "block identity mismatch")
            require(felt(receipt["derived_root"]) == felt(receipt["header_root"]) == felt(case["state_root"]),
                    "computed/header state-root mismatch")
            anchor = receipt["l1_anchor"]
            require(type(anchor["covered_through"]) is int and anchor["covered_through"] >= number and
                    re.fullmatch("0x[0-9a-fA-F]{64}", anchor["transaction_hash"]), "missing covering L1 anchor")
            require(felt(anchor["derived_root"]) == felt(anchor["contract_root"]), "L1 anchor root mismatch")
            asset(root, case["source"])
            witness = asset(root, case["witness"])
            with witness.open("rb") as stream:
                document = json.load(stream)
            identity = document["os_hints_config"]["chain_info"]["chain_id"]
            require(felt(identity) == int.from_bytes(b"SN_MAIN", "big"), "witness chain identity mismatch")
            blocks_in_witness = document["os_input"]["os_block_inputs"]
            require(len(blocks_in_witness) == 1 and blocks_in_witness[0]["block_info"]["block_number"] == number
                    and felt(blocks_in_witness[0]["new_block_hash"]) == felt(case["block_hash"]),
                    f"witness does not describe sampled block {number}")
            del document, blocks_in_witness
            reference = asset(root, case["rust_pie"])
            output = Path(directory) / f"{number}.zip"
            request = dict(schema=1, revision=data["revision"], program=str(program), witness=str(witness),
                           output=str(output))
            command = subprocess.run([host, "v1"], input=json.dumps(request), text=True, capture_output=True,
                                     timeout=180, check=False)
            reply = json.loads(command.stdout)
            require(command.returncode == 0 and reply["schema"] == 1 and reply["status"] == "ok",
                    f"candidate refused block {number}: {reply.get('code')}")
            checksum = digest(output)
            require(checksum == reply["sha256"] == case["rust_pie"]["sha256"] and
                    reference.stat().st_size == output.stat().st_size == reply["bytes"],
                    f"complete Rust PIE differs at block {number}")
            results.append(dict(number=number, block_hash=case["block_hash"], categories=sorted(ids),
                                source_sha256=case["source"]["sha256"], witness_sha256=case["witness"]["sha256"],
                                bytes=reply["bytes"], sha256=checksum))
            output.unlink()
    require(categories == CATEGORIES and len(compiler_versions) >= 2, "incomplete workload or compiler coverage")
    return dict(schema=1, chain_id="SN_MAIN", revision=data["revision"], manifest_sha256=trusted_digest, cases=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--trusted-sha256", required=True)
    parser.add_argument("--host", required=True, type=Path)
    args = parser.parse_args()
    try:
        receipt = qualify(args.manifest, args.trusted_sha256, args.host.absolute())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"corpus qualification failed: {exc}\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
