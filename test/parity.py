#!/usr/bin/env python3
"""Compare independent Cairo CLI executions over a directory of compiled programs."""
import argparse
import concurrent.futures
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
import zlib
from dataclasses import dataclass, field


# Match the complete diagnostic at exit 1. Keep classes narrow: native CLIs
# also use exit 1 for file I/O, internal errors and unrecognised hints.
PRIME = "0x800000000000011000000000000000000000000000000000000000000000001"
REJECTIONS = {
    "wrong-field-prime": {
        "rust": rf'Expected prime {PRIME}, got (0x[0-9a-fA-F]+)\n'
                r'Error: Runner\(Program\(PrimeDiffers\("\1"\)\)\)',
        "ocaml": r"Error: Unexpected Cairo field prime",
    },
    # Rust reports the type, line and column. The fixture pins the affected field.
    "sequence-in-map-field": {
        "ocaml": r"Error: Invalid program metadata at instruction_locations",
        "rust": r'invalid type: sequence, expected a map at line ([0-9]+) column ([0-9]+)\n'
                r'Error: Runner\(Program\(Parse\(Error\("invalid type: sequence, expected a map", '
                r'line: \1, column: \2\)\)\)\)',
    },
    "pie-memory-address-out-of-bounds": {
        "rust": r"Invalid address\nError: Runner\(CairoPieValidation\(InvalidAddress\)\)",
        "ocaml": r"Error: Invalid address",
    },
    "missing-main": {
        "rust": r'Entrypoint main not found\nError: Runner\(Program\(EntrypointNotFound\("main"\)\)\)',
        "ocaml": r"Error: Entrypoint main not found",
    },
}
PASS = {"PASS", "EXPECTED_REJECTION"}


@dataclass
class Observation:
    kind: str
    detail: str = ""
    artifacts: dict = field(default_factory=dict)


def rejection(oracle, diagnostic):
    for reason, patterns in REJECTIONS.items():
        pattern = "reject " + re.escape(reason) if oracle == "lean" else patterns.get(oracle)
        if pattern and re.fullmatch(pattern, diagnostic):
            return reason
    return None


def invalid_constant(value):
    raise ValueError(f"invalid JSON constant {value}")


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate key {key}")
        obj[key] = value
    return obj


def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(block)
    return result.digest()


def artifact(path, kind):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("expected a regular file")
    if kind in ("trace", "memory"):
        width = 24 if kind == "trace" else 40
        if not info.st_size or info.st_size % width:
            raise ValueError(f"{info.st_size} bytes, expected nonempty {width}-byte records")
        with path.open("rb") as src:
            return digest(src)

    if kind == "pie":
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            required = {"version.json", "metadata.json", "memory.bin",
                        "additional_data.json", "execution_resources.json"}
            if len(names) != len(set(names)) or not required.issubset(names):
                raise ValueError("duplicate or missing PIE members")
            members = {}
            for name in names:
                with archive.open(name) as src:
                    members[name] = digest(src)
            return members

    raw = path.read_bytes()
    obj = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if not isinstance(obj, dict):
        raise ValueError("expected an AIR JSON object")
    if kind == "private":
        for name in ("trace", "memory"):
            if obj.pop(name + "_path", None) != str(path.with_name(name)):
                raise ValueError(f"wrong or missing {name}_path")
        return json.dumps(obj, sort_keys=True)

    # Preserve byte comparison outside the unordered public memory_segments map.
    segments = obj.get("memory_segments")
    if not isinstance(segments, dict):
        raise ValueError("missing memory_segments map")
    text = raw.decode()
    # The document was parsed above. Walk only its top-level key/value spans
    # so a nested field of the same name cannot hide a byte difference.
    decoder = json.JSONDecoder()
    pos = text.index("{") + 1
    while True:
        start = re.compile(r"\s*").match(text, pos).end()
        key, end = decoder.raw_decode(text, start)
        start = re.compile(r"\s*:\s*").match(text, end).end()
        _, end = decoder.raw_decode(text, start)
        if key == "memory_segments":
            return text[:start], json.dumps(segments, sort_keys=True), text[end:]
        pos = text.index(",", end) + 1


def independent_env():
    env = os.environ.copy()
    for key in ("CAIRO_VM_RUST_CLI", "CAIRO_VM_DELEGATED"):
        env.pop(key, None)
    return env


def prepare_replay(binary, program, path, args):
    cmd = [binary, program, "--layout", args.layout, "--cairo_pie_output", path]
    if args.layout_params:
        cmd += ["--cairo_layout_params_file", args.layout_params]
    try:
        result = subprocess.run(cmd, capture_output=True, env=independent_env(), timeout=args.timeout)
        if result.returncode:
            return f"Rust PIE generation exited {result.returncode}: {result.stderr[:240]!r}"
        artifact(path, "pie")
    except (subprocess.TimeoutExpired, OSError, ValueError, EOFError, RuntimeError,
            zipfile.BadZipFile, zlib.error) as exc:
        return f"Rust PIE generation failed: {exc}"
    return None


def observe(oracle, binary, program, directory, args):
    directory.mkdir()
    flags = {"trace": "--trace_file", "memory": "--memory_file"}
    cmd = [binary, program, "--layout", args.layout, "--print_output"]
    if args.from_pie:
        cmd.append("--run_from_cairo_pie")
    if args.layout_params:
        cmd += ["--cairo_layout_params_file", args.layout_params]
    if args.proof:
        cmd += ["--proof_mode", "--fill-holes", "false"]
        flags.update(public="--air_public_input", private="--air_private_input")
    if args.pie or args.from_pie:
        flags["pie"] = "--cairo_pie_output"
    for name, flag in flags.items():
        cmd += [flag, directory / name]

    try:
        result = subprocess.run(cmd, capture_output=True, env=independent_env(), timeout=args.timeout)
    except subprocess.TimeoutExpired:
        return Observation("TIMEOUT", f"{args.timeout:g}s")
    except OSError as exc:
        return Observation("LAUNCH_ERROR", str(exc))

    if result.returncode:
        diagnostic = result.stderr.decode(errors="replace").rstrip("\r\n")
        if result.returncode == 1:
            reason = rejection(oracle, diagnostic)
            if reason:
                if result.stdout or any(directory.iterdir()):
                    return Observation("UNEXPECTED_OUTPUT", f"output during rejection {reason}")
                return Observation("REJECT", reason)
        crashed = (result.returncode < 0 or result.returncode == 101
                   or diagnostic.startswith("Fatal error: exception"))
        return Observation("CRASH" if crashed else "UNEXPECTED_EXIT",
                           f"exit={result.returncode} {diagnostic[:240]!r}")

    if not result.stdout:
        return Observation("MISSING_ARTIFACT", "stdout (--print_output)")
    outputs = {"stdout": result.stdout}
    for name in flags:
        try:
            outputs[name] = artifact(directory / name, name)
        except FileNotFoundError:
            return Observation("MISSING_ARTIFACT", name)
        except (OSError, ValueError, EOFError, RuntimeError, zipfile.BadZipFile, zlib.error) as exc:
            return Observation("INVALID_ARTIFACT", f"{name}: {exc}")
    return Observation("SUCCESS", artifacts=outputs)


def check(program, oracles, expected, args):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        if args.from_pie:
            source = root / "input.pie.zip"
            error = prepare_replay(oracles["rust"], program, source, args)
            if error:
                return "FAIL", error
            program = source
        runs = {name: observe(name, binary, program, root / name, args)
                for name, binary in oracles.items()}
    outcomes = ", ".join(f"{name}={r.kind} {r.detail}".rstrip() for name, r in runs.items())
    if expected and all(r.kind == "REJECT" and r.detail == expected for r in runs.values()):
        return "EXPECTED_REJECTION", expected
    if expected or any(r.kind != "SUCCESS" for r in runs.values()):
        return "FAIL", f"expected {expected or 'success'}; {outcomes}"

    differences = []
    for (a, left), (b, right) in itertools.combinations(runs.items(), 2):
        fields = [k for k in left.artifacts if left.artifacts[k] != right.artifacts[k]]
        if fields:
            differences.append(f"{a}/{b}: {', '.join(fields)}")
    if differences:
        return "MISMATCH", "; ".join(differences)
    return "PASS", ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust")
    parser.add_argument("ocaml")
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--lean", metavar="ADAPTER")
    parser.add_argument("--expect-rejections", type=Path, metavar="JSON")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--proof", action="store_true")
    modes.add_argument("--pie", action="store_true")
    modes.add_argument("--from_pie", action="store_true",
                       help="generate a Rust PIE, replay it on every VM, and compare output PIEs")
    parser.add_argument("--layout")
    parser.add_argument("--layout_params")
    parser.add_argument("--filter", default="")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("-j", type=int, default=max(1, (os.cpu_count() or 1) // 2))
    args = parser.parse_args()
    args.layout = args.layout or ("starknet_with_keccak" if args.proof else "all_cairo")
    if args.j < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("jobs and timeout must be positive and finite")
    oracles = {"rust": args.rust, "ocaml": args.ocaml}
    if args.lean is not None:
        oracles["lean"] = args.lean
    for name, binary in oracles.items():
        path = shutil.which(binary)
        if path is None:
            parser.error(f"{name} executable unavailable: {binary}")
        oracles[name] = path
    for a, b in itertools.combinations(oracles, 2):
        if os.path.samefile(oracles[a], oracles[b]):
            parser.error(f"{a} and {b} resolve to the same executable")

    corpus = sorted(p for p in args.corpus.glob("*.json") if p.is_file())
    selected = [p for p in corpus if args.filter in str(p)]
    if not selected:
        parser.error("no selected *.json fixtures")
    expectations = {}
    if args.expect_rejections:
        try:
            expectations = json.loads(args.expect_rejections.read_bytes(), object_pairs_hook=unique_object)
            if not isinstance(expectations, dict):
                raise ValueError("expected a fixture-to-reason object")
            names = {p.name for p in corpus}
            for name, reason in expectations.items():
                if name not in names or not isinstance(reason, str) or reason not in REJECTIONS:
                    raise ValueError(f"unknown fixture or rejection: {name} = {reason!r}")
        except (OSError, ValueError) as exc:
            parser.error(str(exc))

    def one(program):
        return check(program, oracles, expectations.get(program.name), args)

    counts = {}
    with concurrent.futures.ThreadPoolExecutor(args.j) as pool:
        for program, (status, detail) in zip(selected, pool.map(one, selected)):
            counts[status] = counts.get(status, 0) + 1
            if args.verbose or status not in PASS:
                print(f"{status:20} {program.name} {detail}", flush=True)
    print("SUMMARY", "oracles=" + ",".join(oracles),
          *(f"{k}={v}" for k, v in sorted(counts.items())), f"total={len(selected)}")
    return int(bool(counts.keys() - PASS))


if __name__ == "__main__":
    raise SystemExit(main())
