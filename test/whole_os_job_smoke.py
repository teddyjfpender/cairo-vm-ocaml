"""Run the offline adapter on a synthetic cende record with explicit VM test doubles."""
import argparse
import gzip
import json
import shutil
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
import echonet_job
from qualify_os_host import digest
from whole_os_job import run_arm


def executable(root, name, code):
    path = root / name
    path.write_text("#!" + sys.executable + "\n" + code)
    path.chmod(0o755)
    return dict(path=name, sha256=digest(path))


def smoke(sequencer, temp):
    fixture = ROOT / "bench/examples/echonet-genesis.json"
    source = temp / "record.gz"
    source.write_bytes(gzip.compress(fixture.read_bytes(), mtime=0))
    archive = ROOT / "test/pie_run/rust4-bitwise.zip"
    program = temp / "program"
    program.write_text("synthetic compiler identity")
    # Exercise the real embedding check, pinned builder, VM argv and output gate.
    common = f"import shutil, sys\nfrom pathlib import Path\nref = {str(archive)!r}\n"
    rust = executable(temp, "rust-test", common + "# synthetic compiler identity\n"
                      "assert sys.argv[3:] == ['--merge-extra-segments']\nshutil.copy(ref, sys.argv[2])\n")
    ox = executable(temp, "cairo-vm-cli", common +
                    "if '--print_output' in sys.argv:\n"
                    " assert sys.argv[2:3] == ['--os_hints'] and sys.argv[4:-1] == "
                    "['--layout','all_cairo','--print_output','--pie_profile','rust-3.2',"
                    "'--merge_extra_segments','--cairo_pie_output']\n"
                    " shutil.copy(ref, sys.argv[-1])\n"
                    "else:\n"
                    " assert '--max_steps' in sys.argv and '--merge_extra_segments' in sys.argv\n"
                    " shutil.copy(ref, sys.argv[sys.argv.index('--cairo_pie_output')+1])\n")
    plan = dict(pipeline=dict(rust=rust, oxcairo=ox, program=dict(path="program", sha256=digest(program)),
                              compilers={}, sequencer=str(sequencer)))
    commands = echonet_job.commands(temp, plan, dict(revision=echonet_job.REVISION), temp)

    # Echonet emits fixed-width gas prices and omits absent version overrides.
    witness = json.loads((ROOT / "test/fixtures/os/genesis.json").read_bytes())
    block, = witness["os_input"]["os_block_inputs"]
    del block["starknet_version_override"]
    for prices in block["block_info"]["gas_prices"].values():
        for name in prices:
            prices[name] = f"0x{int(prices[name], 16):032x}"
    ref = temp / "reference.json"
    ref.write_text(json.dumps(witness, indent=2))
    hashes = [digest(source), echonet_job.canonical_witness_hash(ref), digest(archive)]
    for arm in commands:
        work = temp / arm / "work"
        work.parent.mkdir()
        row = run_arm(commands[arm] + hashes, source, work.parent / "block.zip", work, hashes[-1], 30)
        stages = json.loads((work / "stages.json").read_bytes())
        assert set(stages) == {"acquire", "decompress", "compile_classes", "prepare_witness",
                               "execute_and_encode_pie", "validate_archive", "deliver"}
        assert all(v > 0 for v in stages.values()) and sum(stages.values()) <= row["wall_ns"]
        assert row["max_rss_kib"] > 0
    host = temp / "oxcairo-os-host"
    shutil.copy2(ROOT / "host/oxcairo-os-host", host)
    plan["pipeline"]["host"] = dict(path=host.name, sha256=digest(host))
    tools = temp / "supervised"
    tools.mkdir()
    installed = echonet_job.commands(temp, plan, dict(revision=echonet_job.REVISION), tools)
    profile = temp / "profile.json"
    profile.write_text(json.dumps(dict(revision=echonet_job.REVISION, program_sha256=digest(program))))
    from unittest.mock import patch
    with patch.dict("os.environ", OXCAIRO_OS_PROFILE=str(profile)):
        run_arm(installed["oxcairo"] + hashes, source, tools / "published.zip", tools / "work", hashes[-1], 30)
    # The adapter validates the host receipt independently of the bytes it stages.
    fake = executable(temp, "wrong-receipt", common + "import json\nrequest=json.load(sys.stdin)\n"
                      "shutil.copy(ref, request['output'])\nprint(json.dumps({'schema':1,'status':'ok',"
                      "'output':request['output'],'sha256':'wrong'}))\n")
    config = tools / "tools.json"
    changed = json.loads(config.read_bytes())
    changed["host"] = str(temp / fake["path"])
    config.write_text(json.dumps(changed))
    refused = tools / "refused"
    refused.mkdir()
    try:
        echonet_job.run(config, "oxcairo", source, refused / "published.zip", refused, *hashes)
    except ValueError as exc:
        assert "receipt mismatch" in str(exc)
    else:
        raise AssertionError("accepted incorrect host receipt")
    assert not (refused / "published.zip").exists()
    for i, message in enumerate(("recording", "witness", "PIE")):
        wrong = hashes.copy()
        wrong[i] = "0" * 64
        work = temp / ("bad-" + message)
        work.mkdir()
        output = work / "published"
        try:
            echonet_job.run(temp / "tools.json", "rust", source, output, work, *wrong)
        except ValueError as exc:
            assert message in str(exc)
        else:
            raise AssertionError(f"accepted incorrect {message}")
        assert not output.exists()

    compiler = executable(temp, "compiler", "import sys\nfrom pathlib import Path\n"
                          "assert sys.argv[2:] == ['--add-pythonic-hints','--allowed-libfuncs-list-name','all']\n"
                          "print(Path(sys.argv[1]).read_text())\n")
    classes = {"0x1": {"compiler": "v1", "class": {"marker": 1}}}
    assert echonet_job.compile_classes({"sierra": classes}, {"v1": temp / compiler["path"]}, temp) == {
        "0x1": {"marker": 1}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sequencer", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        smoke(args.sequencer.resolve(), Path(directory))
    print("Synthetic job adapter checks passed")
