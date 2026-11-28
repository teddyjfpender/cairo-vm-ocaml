#!/usr/bin/env python3
"""Fault-injecting CLI for the harness tests. Its basename selects the oracle."""
import json
import os
from pathlib import Path
import signal
import sys
import time
import zipfile

name = Path(sys.argv[0]).name
action = json.loads(Path(sys.argv[1]).read_text()).get(name, "success")
if "CAIRO_VM_RUST_CLI" in os.environ or "CAIRO_VM_DELEGATED" in os.environ:
    sys.exit(9)
if action == "timeout":
    time.sleep(30)
if action == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
if action == "panic":
    sys.exit(101)
if action == "usage":
    sys.exit(2)
if action == "uncaught":
    print('Fatal error: exception Invalid_argument("Array.make")', file=sys.stderr)
    sys.exit(2)
if action == "dirty":
    print("Program Output:")
    action = "prime"
if action in ("prime", "main", "unknown", "extra"):
    prime = {
        "rust": 'Expected prime 0x800000000000011000000000000000000000000000000000000000000000001, got 0x11\n'
                'Error: Runner(Program(PrimeDiffers("0x11")))',
        "ocaml": "Error: Unexpected Cairo field prime",
        "lean": "reject wrong-field-prime",
    }
    main = {
        "rust": 'Entrypoint main not found\nError: Runner(Program(EntrypointNotFound("main")))',
        "ocaml": "Error: Entrypoint main not found",
        "lean": "reject missing-main",
    }
    message = {"prime": prime[name], "main": main[name], "unknown": "disk full",
               "extra": "I/O error\n" + prime[name]}[action]
    print(message, file=sys.stderr)
    sys.exit(1)


def output(flag):
    return Path(sys.argv[sys.argv.index(flag) + 1])


if action != "missing-stdout":
    print("changed" if action == "stdout" else "Program Output:")
for kind, flag, size in [("trace", "--trace_file", 24), ("memory", "--memory_file", 40)]:
    if action != "missing-" + kind:
        output(flag).write_bytes(bytes([int(action == kind)]) * size)
if "--proof_mode" in sys.argv:
    segs = {"a": {}, "b": {}}
    if name == "ocaml":
        segs = dict(reversed(segs.items()))
    pub = json.dumps({"memory_segments": segs, "n_steps": 1 + int(action == "public")}, indent=2)
    if action == "format":
        pub += "\n"
    if action != "missing-public":
        output("--air_public_input").write_text("{" if action == "bad-json" else pub)
    if action != "missing-private":
        output("--air_private_input").write_text(json.dumps({
            "trace_path": str(output("--trace_file")) if action != "bad-path" else "elsewhere",
            "memory_path": str(output("--memory_file")),
            "range_check": [int(action == "private")],
        }))
if "--cairo_pie_output" in sys.argv and action != "missing-pie":
    path = output("--cairo_pie_output")
    if action == "bad-zip":
        path.write_bytes(b"not an archive")
    else:
        method = zipfile.ZIP_DEFLATED if name == "rust" else zipfile.ZIP_STORED
        with zipfile.ZipFile(path, "w", compression=method) as archive:
            for member in ("version.json", "metadata.json", "memory.bin", "additional_data.json",
                           "execution_resources.json"):
                if member != "memory.bin" or action != "missing-member":
                    archive.writestr(member, b"1" if action == "pie" else b"0")
