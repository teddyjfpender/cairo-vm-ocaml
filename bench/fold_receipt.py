#!/usr/bin/env python3
"""Normalize independently produced contiguous fold rows and an observed L1 anchor."""
import argparse
import json
from pathlib import Path
import re

from qualify_os_host import digest, felt, require


def receipt(rows_path, header_path, anchors_path, anchor_height):
    header = json.loads(header_path.read_bytes())
    height = header["block_number"]
    require(type(height) is int and 0 <= height <= anchor_height, "invalid sample or covering anchor height")
    header_root = header["state_root"]
    felt(header["block_hash"])
    roots = json.loads(anchors_path.read_bytes())["anchors"]
    matches = [a for a in roots if a["block_number"] == anchor_height]
    require(len(matches) == 1, "expected one independent L1 observation at the selected anchor")
    anchor = matches[0]
    require(re.fullmatch(r"0x[0-9a-fA-F]{64}", anchor["tx_hash"]), "invalid L1 transaction hash")
    last = -1
    derived = None
    with rows_path.open("rb") as stream:
        for line in stream:
            row = json.loads(line)
            start, end = row["first"], row["last"]
            require(type(start) is int and type(end) is int and start == last + 1 and end >= start,
                    "non-contiguous fold log")
            require(row["blocks"] == end - start + 1 and row["check"] in ("header", "header+l1"),
                    "row lacks successful complete header check")
            require(not start <= height < end, "sample must be a verified batch endpoint")
            if height == end:
                derived = row["root"]
                require(felt(derived) == felt(header_root), "sampled root differs from its header")
            last = end
            if end >= anchor_height:
                require(end == anchor_height and row["check"] == "header+l1", "missing L1 verification row")
                require(felt(row["root"]) == felt(anchor["global_root"]), "anchor root mismatch")
                if height == end:
                    require(felt(header["block_hash"]) == felt(anchor["block_hash"]), "anchored header hash mismatch")
                break
        else:
            raise ValueError("fold does not reach the covering anchor")
    require(derived is not None, "fold lacks sampled block")
    return dict(chain_id="SN_MAIN", number=height, block_hash=header["block_hash"], derived_root=derived,
                header_root=header_root, l1_anchor=dict(covered_through=anchor_height, transaction_hash=anchor["tx_hash"],
                derived_root=row["root"], contract_root=anchor["global_root"]), fold_log_sha256=digest(rows_path),
                header_sha256=digest(header_path), l1_observations_sha256=digest(anchors_path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("fold_rows", "header", "anchors"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--anchor-height", type=int, required=True)
    args = parser.parse_args()
    try:
        result = receipt(args.fold_rows, args.header, args.anchors, args.anchor_height)
    except (OSError, KeyError, TypeError, ValueError) as exc:
        parser.exit(1, f"state-fold receipt rejected: {exc}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
