"""Compare proof-mode raw OS snapshots with the pinned Rust hint processor."""
import argparse
import gzip
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("program", "ocaml", "rust", "adapter"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    fixtures = Path(__file__).resolve().parents[3] / "test/fixtures/os"
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        for case in ("genesis", "multi-block", "account", "reverted-invoke"):
            witness = fixtures / "genesis.json"
            if case != "genesis":
                witness = work / "input.json"
                with gzip.open(fixtures / f"{case}.json.gz") as source:
                    witness.write_bytes(source.read())
            for layout in ("all_cairo_stwo", "all_cairo"):
                snapshots = []
                for engine in ("ocaml", "rust"):
                    output = work / f"{engine}.json"
                    if engine == "ocaml":
                        cmd = [args.ocaml, args.program, output, "--os", witness, "--layout", layout]
                    else:
                        cmd = [args.rust, args.program, witness, output, "os", layout]
                    result = subprocess.run(cmd, capture_output=True, text=True)
                    if case in ("account", "reverted-invoke") and layout == "all_cairo_stwo":
                        if result.returncode == 0 or "Expected relocatable at address" not in result.stderr:
                            raise ValueError(f"expected missing builtin rejection: {case} {engine}")
                        continue
                    result.check_returncode()
                    snapshots.append(output)
                if snapshots:
                    if layout == "all_cairo_stwo":
                        for i, source in enumerate(snapshots):
                            output = work / f"input-{i}.json"
                            subprocess.run([args.adapter, source, output], check=True)
                            snapshots[i] = output
                    left, right = (json.loads(path.read_bytes()) for path in snapshots)
                    if layout == "all_cairo":
                        # Public offsets can be emitted in either order. Preserve
                        # every (offset, page) pair, including multiplicities.
                        for state in (left, right):
                            for offsets in state["public"].values():
                                offsets.sort()
                    if left != right:
                        raise ValueError(f"snapshot mismatch: {case} {layout}")
                print(case, layout, "matched" if snapshots else "both rejected", flush=True)


if __name__ == "__main__":
    main()
