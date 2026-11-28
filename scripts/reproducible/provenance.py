"""Describe the immutable build inputs, resulting package and dynamic dependencies."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


archive = Path(sys.argv[1])
inputs = dict(line.split("=", 1) for line in Path("scripts/reproducible/sources.env").read_text().splitlines()
              if line and not line.startswith("#"))
programs = sorted(Path("test/fixtures/programs").glob("*.gz"))
executables = ["_build/default/bin/main.exe", "_build/default/bench/native_os_worker.exe",
               "_build/default/bindings/c/oxcairo.so"]
runtime = {}
for exe in executables:
    # ldd prints process-specific mapping addresses; keep the resolved object paths.
    libs = [word for line in command("ldd", exe).splitlines() for word in line.split() if word.startswith("/")]
    runtime[Path(exe).name] = {lib: digest(lib) for lib in sorted(set(libs))}
source = command("git", "-c", "safe.directory=/checkout", "-C", "/checkout", "rev-parse", "HEAD")
record = {
    "schema": 1, "source_commit": source, "inputs": inputs,
    "package": {"name": archive.name, "sha256": digest(archive)},
    "os_release": Path("/etc/os-release").read_text(),
    "system_packages": command("dpkg-query", "-W", "-f", "${binary:Package}=${Version}\n").splitlines(),
    "cpu_target": "x86-64",
    "source_tree": command("git", "-c", "safe.directory=/checkout", "-C", "/checkout", "rev-parse", "HEAD^{tree}"),
    "opam_package_metadata_sha256": {p.parent.name: digest(p) for p in sorted(Path("/home/opam/release-opam/release/.opam-switch/packages").glob("*/opam"))},
    "opam_packages": Path("/tmp/resolved.lock").read_text().splitlines(),
    "compiler": {"version": command("ocamlopt", "-version"), "sha256": digest(command("which", "ocamlopt"))},
    "programs": {str(path): digest(path) for path in programs}, "runtime_libraries": runtime,
}
archive.with_suffix(".gz.provenance.json").write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
