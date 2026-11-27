"""Run against two installed CLIs and cairo-compile 0.13.5."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("rust", type=Path)
parser.add_argument("ocaml", type=Path)
parser.add_argument("--compiler", default="cairo-compile")
args = parser.parse_args()
rust, ocaml = args.rust.resolve(), args.ocaml.resolve()
compiler = shutil.which(args.compiler)
if compiler is None:
    parser.error(f"compiler not found: {args.compiler}")
compiler = Path(compiler).resolve()
source = Path(__file__).resolve().with_name("builtin_holes.cairo")
native_env = os.environ.copy()
native_env.pop("CAIRO_VM_RUST_CLI", None)
fallback_env = dict(native_env, CAIRO_VM_RUST_CLI=str(rust))


def compare(argv, *, fallback=False, status=0, files=()):
    observations = []
    for binary in [rust, ocaml]:
        for path in files:
            Path(path).unlink(missing_ok=True)
        result = subprocess.run([binary, *argv], capture_output=True,
                                env=fallback_env if fallback else native_env)
        assert result.returncode == status, (argv, binary, result.stderr)
        artifacts = []
        for path in files:
            if path.endswith(".zip"):
                with zipfile.ZipFile(path) as archive:
                    artifacts.append({name: archive.read(name) for name in archive.namelist()})
            elif path.endswith(".json"):
                artifacts.append(json.loads(Path(path).read_text()))
            else:
                artifacts.append(Path(path).read_bytes())
        observations.append((result.stdout, artifacts))
    assert observations[0] == observations[1], argv
    return observations[0]


with tempfile.TemporaryDirectory() as tmp:
    os.chdir(tmp)
    for proof, name in [(False, "program.json"), (True, "proof.json")]:
        subprocess.run([compiler, *(["--proof_mode"] if proof else []),
                        source.resolve(), "--output", name], check=True)
    subprocess.run([compiler, source.with_name("uint256_mul_div.cairo"),
                    "--output", "uint256.json"], check=True)
    compare(["uint256.json", "--layout=all_cairo", "--trace_file=trace", "--memory_file=mem"],
            files=["trace", "mem"])
    compare(["uint256.json", "--layout=all_cairo", "--entrypoint=zero_divisor"], status=1)
    base = ["--layout=all_cairo", "--print_output", "--entrypoint=main"]
    sizes = []
    for fill in ["false", "true"]:
        output, _ = compare([*base, "--trace_file", "trace", "--memory_file", "mem",
                             "--fill-holes=" + fill, "--", "program.json"], files=["trace", "mem"])
        assert output == b"Program Output:\n3\n"
        sizes.append(Path("mem").stat().st_size)
    assert sizes[1] == sizes[0] + 2 * 40
    compare(["program.json", "--layout", "all_cairo", "--cairo_pie_output=x.zip"],
            fallback=True, files=["x.zip"])
    compare(["x.zip", *base, "--run_from_cairo_pie"], fallback=True)
    compare(["proof.json", "--proof_mode", "--layout=all_cairo",
             "--air_public_input", "public.json", "--air_private_input", "private.json",
             "--trace_file", "trace", "--memory_file", "mem"], fallback=True,
            files=["public.json", "private.json", "trace", "mem"])
    Path("ecdsa.cairo").write_text("%builtins ecdsa\nfunc main{ecdsa_ptr: felt*}() {\n    return ();\n}\n")
    subprocess.run([compiler, "ecdsa.cairo", "--output", "ecdsa.json"], check=True)
    compare(["ecdsa.json", "--layout=small", "--print_output"], fallback=True)
    for flags in [["-h"], ["--help"], ["-V"], ["--version"]]:
        compare(flags, fallback=True)
    for flags in [[], ["program.json", "extra.json"], ["program.json", "--secure_run", "yes"],
                  ["program.json", "--layout=x"], ["program.json", "--print_output", "--print_output"]]:
        compare(flags, status=2)
    # The native error path must not leave output from a failed execution.
    wrong_prime = json.loads(Path("program.json").read_text())
    wrong_prime["prime"] = "0x11"
    Path("wrong-prime.json").write_text(json.dumps(wrong_prime))
    compare(["wrong-prime.json", *base], status=1)
    compare(["proof.json", "--air_private_input=private.json"], fallback=True, status=2)
    self_ref = subprocess.run([ocaml, "program.json", "--proof_mode"], capture_output=True,
                              env=dict(native_env, CAIRO_VM_RUST_CLI=str(ocaml)), timeout=5)
    assert self_ref.returncode == 2 and b"this executable" in self_ref.stderr
    if Path("/dev/full").exists():
        compare(["program.json", "--layout", "all_cairo", "--memory_file", "/dev/full"], status=1)
print("CLI comparisons passed")
