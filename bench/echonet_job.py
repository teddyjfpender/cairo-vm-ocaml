"""Offline complete-job adapter for the pinned Echonet cende recording format."""
from contextlib import contextmanager
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from qualify_os_host import asset, digest, require

REVISION = "ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45"


def full_program_pins():
    manifest = Path(__file__).resolve().parents[1] / "test/fixtures/programs/apollo-0.20.0-rc.1/manifest.json"
    apollo = json.loads(manifest.read_bytes())
    return {
        REVISION: "2325e4b7e440c4e5a3f5601585f1b7eb05cc13f2ce6394d5fd640c2e7d9c6ded",
        apollo["sequencer_revision"]: apollo["programs"]["os"]["full_sha256"],
    }


def canonical_witness_hash(path):
    value = hashlib.sha256()
    encoder = json.JSONEncoder(sort_keys=True, separators=(",", ":"))
    for chunk in encoder.iterencode(json.loads(path.read_bytes())):
        value.update(chunk.encode("ascii"))
    return value.hexdigest()


def commands(root, plan, qualification, temp):
    """Resolve and verify all job tools once, outside the measured region."""
    from compare_native_os import embedded_program_digest

    spec = plan["pipeline"]
    revision = qualification["revision"]
    pins = full_program_pins()
    require(revision in pins, "unsupported OS revision")
    paths = {k: str(asset(root, spec[k])) for k in ("rust", "oxcairo", "program")}
    if "host" in spec:
        host = asset(root, spec["host"])
        require(host.with_name("cairo-vm-cli").resolve() == Path(paths["oxcairo"]),
                "host must use the pinned sibling cairo-vm-cli")
        paths["host"] = str(host)
    require(spec["program"]["sha256"] == pins[revision], "full OS compiler digest does not match revision")
    embedded_program_digest(Path(paths["rust"]), Path(paths["program"]))
    paths["revision"] = revision
    paths["compilers"] = {k: str(asset(root, v)) for k, v in spec["compilers"].items()}
    # Import only the builder and its dependencies, directly from the pinned git object.
    package = temp / "echonet"
    package.mkdir()
    for name in ("__init__", "os_input_builder", "echonet_types", "helpers", "constants"):
        filename = name + ".py"
        (package / filename).write_bytes(subprocess.check_output([
            "git", "-C", root / spec["sequencer"], "show", f"{REVISION}:echonet/{filename}"]))
    config = temp / "tools.json"
    config.write_text(json.dumps(paths))
    return {arm: [sys.executable, "-B", str(Path(__file__).resolve()), str(config), arm,
                  "{source}", "{output}", "{work}"] for arm in ("rust", "oxcairo")}


def compile_classes(record, compilers, work):
    compiled = {}
    for casm_hash, entry in record["sierra"].items():
        source = work / "class.json"
        source.write_text(json.dumps(entry["class"]))
        result = subprocess.check_output([compilers[entry["compiler"]], source,
                                          "--add-pythonic-hints", "--allowed-libfuncs-list-name", "all"])
        compiled[casm_hash] = json.loads(result)
    return compiled


def run(config, arm, source, output, work, source_hash, witness_hash, pie_hash):
    sys.path.insert(0, str(config.parent))
    from echonet.os_input_builder import build_os_cli_input, pick_state_commitment_infos

    tools = json.loads(config.read_bytes())
    times = {}

    @contextmanager
    def stage(name):
        start = time.monotonic_ns()
        yield
        times[name] = time.monotonic_ns() - start

    with stage("acquire"):
        local = work / "record.gz"
        shutil.copyfile(source, local)
        require(digest(local) == source_hash, "acquired recording digest mismatch")
    with stage("decompress"):
        with gzip.open(local, "rt", encoding="utf-8") as stream:
            record = json.load(stream)
        number = record["blob"]["state_diff"]["block_info"]["block_number"]
        require(record["blob"]["block_number"] == number and record["next_blob"]["block_number"] == number + 1,
                "recording must contain consecutive cende blocks")
        facts = pick_state_commitment_infos(record["next_blob"], number)
    with stage("compile_classes"):
        classes = compile_classes(record, tools["compilers"], work)
    with stage("prepare_witness"):
        hints = build_os_cli_input(
            record["blob"], state_commitment_infos=facts, block_number=number,
            prev_block_hash=record["block_document"]["parent_block_hash"],
            new_block_hash=record["block_document"]["block_hash"],
            block_hash_commitments_payload=record["block_hash_commitments_payload"],
            chain_id=record["chain_id"], strk_fee_token_address=record["strk_fee_token_address"],
            layout="all_cairo", cairo_pie_zip_path="", raw_os_output_path="")["os_hints"]
        if "full_output" in record:
            require(type(record["full_output"]) is bool, "full_output must be a boolean")
            hints["os_hints_config"]["full_output"] = record["full_output"]
        hints["os_input"].update(compiled_classes=classes,
                                 deprecated_compiled_classes=record["deprecated_compiled_classes"])
        witness = work / "hints.json"
        with witness.open("w", encoding="ascii") as stream:
            json.dump(hints, stream, sort_keys=True, separators=(",", ":"))
        require(digest(witness) == witness_hash, "prepared witness differs from qualification")
        del hints, facts, classes, record
    pie = work / "staged.zip"
    with stage("execute_and_encode_pie"):
        if arm == "rust":
            subprocess.run([tools["rust"], witness, pie, "--merge-extra-segments"],
                           check=True, stdout=subprocess.DEVNULL)
        elif arm == "oxcairo" and "host" in tools:
            request = dict(schema=1, revision=tools["revision"], program=tools["program"], witness=str(witness),
                           output=str(pie), publication="os-host-standard")
            result = subprocess.run([tools["host"], "v1"], input=json.dumps(request), text=True,
                                    stdout=subprocess.PIPE, check=True)
            reply = json.loads(result.stdout)
            require(reply.get("schema") == 1 and reply.get("status") == "ok" and
                    reply.get("output") == str(pie) and reply.get("sha256") == pie_hash and
                    reply.get("bytes") == pie.stat().st_size, "installed host publication receipt mismatch")
        else:
            require(arm == "oxcairo", "unknown arm")
            argv = [tools["oxcairo"], tools["program"], "--os_hints", witness, "--layout", "all_cairo",
                    "--print_output", "--pie_profile", "rust-3.2", "--merge_extra_segments",
                    "--cairo_pie_output", pie]
            subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
    with stage("validate_archive"):
        require(digest(pie) == pie_hash, "staged PIE differs from authenticated reference")
    with stage("deliver"):
        with pie.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(pie, output)
        fd = os.open(output.parent, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    (work / "stages.json").write_text(json.dumps(times))


if __name__ == "__main__":
    config, arm, source, output, work, *hashes = sys.argv[1:]
    run(Path(config), arm, Path(source), Path(output), Path(work), *hashes)
