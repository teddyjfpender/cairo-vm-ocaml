#!/usr/bin/env python3
"""Check exact native CLI exit codes against the Rust v4 reference."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust")
    parser.add_argument("ocaml")
    parser.add_argument("corpus", type=Path)
    args = parser.parse_args()
    env = os.environ.copy()
    for key in ("CAIRO_VM_RUST_CLI", "CAIRO_VM_DELEGATED"):
        env.pop(key, None)

    def check(path, expected, flags=()):
        if not path.is_file():
            raise SystemExit(f"missing input: {path}")
        for label, binary in (("Rust", args.rust), ("OCaml", args.ocaml)):
            result = subprocess.run([binary, path, *flags], env=env,
                                    capture_output=True, text=True, timeout=30)
            if result.returncode != expected:
                raise SystemExit(f"{path.name}: expected {label} exit {expected}, "
                                 f"got {result.returncode}\n{result.stderr}")
        print(f"{path.name}: both exited {expected}")

    check(args.corpus / "manually_compiled" / "overflowing_dict.json", 1)
    program = json.loads((args.corpus / "array_sum.json").read_text())
    program.pop("attributes", None)
    program.pop("debug_info", None)
    # Build the final member as JSON text so the duplicate key survives.
    prefix = json.dumps(program)[:-1] + ","
    cases = (
        ("control", '"attributes":[]', 0),
        ("invalid-debug-locations", '"debug_info":{"instruction_locations":null}', 1),
        ("numeric-attribute-value",
         '"attributes":[{"name":"x","start_pc":0,"end_pc":0,"value":7}]', 1),
        ("duplicate-debug-info", '"debug_info":null,"debug_info":null', 1),
    )
    with tempfile.TemporaryDirectory() as directory:
        packed = Path(directory) / "packed"
        for option in (["--pie_compression_level", "1"], ["--pie_profile", "fast"]):
            for extra, diagnostic in [(option, "option repeated"), (["--pack_program", packed], "takes only a program file")]:
                result = subprocess.run([args.ocaml, args.corpus / "array_sum.json", *option, *extra],
                                        env=env, capture_output=True, text=True, timeout=30)
                if result.returncode != 2 or diagnostic not in result.stderr or packed.exists():
                    raise SystemExit(f"unexpected {option[0]} behavior: {result.stderr}")
        # A single ret lets malformed metadata reach a successful exit when
        # a reader accidentally treats it as empty or ignores an unused ID.
        minimal = {
            "prime": program["prime"], "builtins": [], "data": ["0x208b7fff7fff7ffe"],
            "hints": {}, "reference_manager": {"references": []},
            "identifiers": {"__main__.main": {"type": "function", "pc": 0}},
        }
        malformed = []
        for key in ("hints", "reference_manager"):
            fields = minimal.copy()
            del fields[key]
            malformed.append((f"{key}-missing", json.dumps(fields)))
            for label, value in (("null", None), ("empty-list", []), ("integer", 3), ("bool", False)):
                malformed.append((f"{key}-{label}", json.dumps({**minimal, key: value})))
        for key in minimal:
            source = json.dumps(minimal)[:-1] + "," + json.dumps(key) + ":" + json.dumps(minimal[key]) + "}"
            malformed.append((f"{key}-duplicate", source))
        for name, bad_id in (("numeric-type", {"type": 7}), ("negative-pc", {"type": "label", "pc": -1})):
            malformed.append((name, json.dumps({**minimal, "identifiers": {**minimal["identifiers"], "unused": bad_id}})))
        for name, source in malformed:
            path = Path(directory) / (name + ".json")
            path.write_text(source)
            check(path, 1)
            result = subprocess.run([args.ocaml, path, "--pack_program", packed], env=env,
                                    capture_output=True, timeout=30)
            if result.returncode != 1 or packed.exists():
                raise SystemExit(f"malformed input packed: {name}")
        positional = Path(directory) / "positional-reference-manager.json"
        positional.write_text(json.dumps({**minimal, "reference_manager": [[]]}))
        check(positional, 0)

        for name, member, expected in cases:
            path = Path(directory) / (name + ".json")
            path.write_text(prefix + member + "}")
            check(path, expected, ("--layout", "all_cairo"))


if __name__ == "__main__":
    main()
