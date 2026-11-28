"""Exercise rejection commit points through the test-only process interface."""
import json
import os
import subprocess
import sys


def instruction(offsets, flags):
    a, b, c = (n + 32768 for n in offsets)
    return a | b << 16 | c << 32 | flags << 48


def word(number):
    return {"felt": str(number)}


def run(steps, memory, actions=None):
    req = {"schema": 1, "segments": 3, "trace": True,
           "registers": {"pc": [2, 0], "ap": 1, "fp": 1},
           "memory": memory, "actions": actions or [{"step": steps}]}
    proc = subprocess.run([os.path.abspath(sys.argv[1])], input=json.dumps(req),
                          capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


add = instruction([0, -1, 1], 0x4824)
invalid = instruction([0, -1, 1], 0x481C)
base = [[[2, 0], word(add)], [[1, 0], word(17)]]
for cells in (base, [*base, [[2, 1], word(25)], [[1, 1], word(41)]]):
    snapshot = run(1, cells)
    assert snapshot["steps"] == 0 and not snapshot["trace"]
    assert snapshot["failure"]["step"] == 0
    assert all(not accessed for _, _, accessed in snapshot["memory"])
late = run(2, [*base, [[2, 1], word(25)], [[2, 2], word(invalid)]])
assert late["steps"] == len(late["trace"]) == 1
assert late["failure"]["step"] == 1
assert [[1, 1], word(42), True] in late["memory"]
assert [[2, 2], word(invalid), False] in late["memory"]
changed = run(1, base, [{"skip": True}, {"replace_unaccessed": [[2, 0], word(invalid)]},
                        {"pc": [2, 0]}, {"step": 1}])
assert changed["failure"] == {"step": 0, "error": "Invalid op1_reg value: 7"}
assert not changed["trace"]
