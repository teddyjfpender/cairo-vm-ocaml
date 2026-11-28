"""Bounded single-field witness mutations compared with a typed pinned Rust oracle."""
import argparse
import copy
import json
from pathlib import Path
import random
import subprocess
import tempfile


def exercise(host, program, witness, reference=None):
    source = json.loads(witness.read_bytes())
    rng = random.Random(1860)
    fields = [("new_block_hash",), ("prev_block_hash",), ("contract_class_commitment_info","updated_root"),
              ("contract_state_commitment_info","updated_root")]
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        changed = temp / "changed.json"
        output = temp / "published.zip"
        output.write_bytes(b"previous successful publication")
        job = dict(schema=1, revision="1860b9850b5c51858c50c0f5038933e49f932eef", program=str(program),
                   witness=str(changed), output=str(output))
        for field in fields:
            for _ in range(2):
                case = copy.deepcopy(source)
                block = case["os_input"]["os_block_inputs"][0]
                value = block
                for key in field[:-1]:
                    value = value[key]
                bit = rng.randrange(240)
                value[field[-1]] = hex(int(value[field[-1]], 16) ^ (1 << bit))
                changed.write_text(json.dumps(case))
                if reference:
                    oracle = subprocess.run([reference,changed], capture_output=True, timeout=10)
                    assert oracle.returncode == 5 and oracle.stdout.startswith(b"vm_exception "), (field, bit, oracle)
                result = subprocess.run([host,"v1"],input=json.dumps(job),text=True,capture_output=True,timeout=10)
                reply = json.loads(result.stdout)
                assert result.returncode == 5 and reply["code"] == "invalid_input", (field, bit, result)
                assert output.read_bytes() == b"previous successful publication"
    print("Apollo witness seed 1860: eight altered block hashes and commitment roots refused")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("host", "program", "witness"):
        parser.add_argument(argument, type=Path)
    parser.add_argument("--reference", type=Path)
    args = parser.parse_args()
    exercise(args.host.absolute(),args.program.resolve(),args.witness.resolve(),args.reference)
