"""Exercise the real independent oracle and confirm a single corrupted Lean trace fails."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
rust, ocaml = (Path(p).resolve() for p in sys.argv[1:])
adapter = root / "test/lean/run"
common = [sys.executable, root / "test/parity.py", rust, ocaml]
options = ["--layout", "small", "--verbose", "--timeout", "90"]
subprocess.run([*common, root / "test/parity_fixtures/core", "--lean", adapter, "--expect-rejections",
                root / "test/parity_fixtures/core-rejections.json", *options], check=True)
fixtures = root / "test/lean/fixtures"
subprocess.run([*common, fixtures, "--lean", adapter, *options], check=True)
with tempfile.TemporaryDirectory() as td:
    wrapper = Path(td) / "corrupt-trace"
    wrapper.write_text("""#!/usr/bin/env python3
import os, pathlib, subprocess, sys
args = sys.argv[1:]
status = subprocess.run([os.environ["REAL_LEAN_ADAPTER"], *args]).returncode
if status:
    sys.exit(status)
trace = pathlib.Path(args[args.index("--trace_file") + 1])
data = bytearray(trace.read_bytes())
data[0] ^= 1
trace.write_bytes(data)
""")
    wrapper.chmod(0o755)
    run = subprocess.run([*common, fixtures, "--lean", wrapper, *options],
                         env={**os.environ, "REAL_LEAN_ADAPTER": str(adapter)}, capture_output=True, text=True)
    print(run.stdout, end="")
    expected = {p.name for p in fixtures.glob("*.json")}
    mismatches = set(re.findall(r"^MISMATCH\s+(\S+?)\s+rust/lean: trace; ocaml/lean: trace$", run.stdout, re.M))
    if run.returncode != 1 or mismatches != expected:
        raise SystemExit(f"corrupted Lean trace did not produce each expected disagreement: {run.stderr}")
