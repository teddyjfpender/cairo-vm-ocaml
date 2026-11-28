"""Black-box regression tests for test/parity.py; requires only Python."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


TEST = Path(__file__).resolve().parent


class ParityGate(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.corpus = self.root / "corpus"
        self.corpus.mkdir()
        self.program = self.corpus / "case.json"
        self.expect = self.root / "rejections.json"
        self.expect.write_text('{"case.json": "wrong-field-prime"}')
        for name in ("rust", "ocaml", "lean"):
            path = self.root / name
            shutil.copyfile(TEST / "parity_fixtures" / "fake_cli.py", path)
            path.chmod(0o755)

    def gate(self, rust="success", ocaml="success", lean=None, expected=False, flags=(),
             code=0, contains=()):
        self.program.write_text(json.dumps(dict(rust=rust, ocaml=ocaml, lean=lean)))
        cmd = [sys.executable, TEST / "parity.py", self.root / "rust", self.root / "ocaml",
               self.corpus, "--verbose", "-j", "1", *flags]
        if lean is not None:
            cmd.extend(["--lean", self.root / "lean"])
        if expected:
            cmd.extend(["--expect-rejections", self.expect])
        env = dict(os.environ, CAIRO_VM_RUST_CLI="must-be-unset", CAIRO_VM_DELEGATED="1")
        p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=10)
        report = p.stdout + p.stderr
        self.assertEqual(p.returncode, code, report)
        for fragment in contains:
            self.assertIn(fragment, report)

    def test_success_modes_and_normalizations(self):
        for flags in [(), ("--proof",), ("--pie",), ("--from_pie",)]:
            with self.subTest(flags=flags):
                self.gate(lean="success", flags=flags, contains=["PASS=1", "oracles=rust,ocaml,lean"])

    def test_replay_requires_valid_input_and_matching_outputs(self):
        for action in ("missing-pie", "bad-zip", "missing-member", "unknown"):
            with self.subTest(action=action):
                self.gate(rust=action, flags=["--from_pie"], code=1,
                          contains=["FAIL=1", "Rust PIE generation"])
        self.gate(ocaml="pie", flags=["--from_pie"], code=1,
                  contains=["MISMATCH=1", "rust/ocaml: pie"])

    def test_only_reviewed_rejection_passes(self):
        self.gate("prime", "prime", "prime", expected=True, contains=["EXPECTED_REJECTION=1"])
        for a, b in [("prime", "main"), ("main", "main"), ("unknown", "unknown"),
                     ("prime", "success"), ("success", "success"), ("prime", "extra"), ("dirty", "prime")]:
            with self.subTest(a=a, b=b):
                self.gate(a, b, expected=True, code=1, contains=["FAIL=1"])
        self.gate("prime", "prime", code=1, contains=["expected success", "REJECT wrong-field-prime"])

    def test_timeouts(self):
        for other, label in [("timeout", "TIMEOUT"), ("prime", "REJECT")]:
            self.gate("timeout", other, expected=True, flags=["--timeout", "0.4"],
                      code=1, contains=["rust=TIMEOUT", "ocaml=" + label])

    def test_crashes_and_unexpected_exits(self):
        for action, kind in [("signal", "CRASH"), ("panic", "CRASH"), ("uncaught", "CRASH"),
                             ("usage", "UNEXPECTED_EXIT"), ("unknown", "UNEXPECTED_EXIT")]:
            with self.subTest(action=action):
                self.gate(action, action, expected=True, code=1,
                          contains=["rust=" + kind, "ocaml=" + kind])

    def test_missing_and_invalid_outputs(self):
        for name, flags in [("stdout", ()), ("trace", ()), ("memory", ()), ("public", ["--proof"]),
                            ("private", ["--proof"]), ("pie", ["--pie"])]:
            with self.subTest(name=name):
                self.gate("missing-" + name, "missing-" + name, flags=flags, code=1,
                          contains=["rust=MISSING_ARTIFACT " + name, "ocaml=MISSING_ARTIFACT " + name])
        self.gate(ocaml="missing-trace", code=1, contains=["rust=SUCCESS", "ocaml=MISSING_ARTIFACT"])
        for action, flags in [("bad-zip", ["--pie"]), ("missing-member", ["--pie"]),
                              ("bad-json", ["--proof"]), ("bad-path", ["--proof"])]:
            self.gate(action, action, flags=flags, code=1, contains=["INVALID_ARTIFACT"])

    def test_artifact_disagreement(self):
        for field, flags in [("stdout", ()), ("trace", ()), ("memory", ()), ("public", ["--proof"]),
                             ("private", ["--proof"]), ("pie", ["--pie"]), ("format", ["--proof"])]:
            with self.subTest(field=field):
                self.gate(ocaml=field, flags=flags, code=1, contains=["MISMATCH=1", "rust/ocaml"])

    def test_independent_oracle_can_disagree_with_both(self):
        self.gate(lean="trace", code=1, contains=["rust/lean: trace", "ocaml/lean: trace"])
        self.gate("prime", "prime", "main", expected=True, code=1, contains=["lean=REJECT missing-main"])
        self.gate(lean="usage", code=1, contains=["lean=UNEXPECTED_EXIT"])
        self.gate(lean="missing-memory", code=1, contains=["lean=MISSING_ARTIFACT"])

    def test_configuration_fails_closed(self):
        self.gate(flags=["--filter", "typo"], code=2, contains=["no selected"])
        self.gate(flags=["--lean", self.root / "missing"], code=2, contains=["lean executable unavailable"])
        self.gate(flags=["--lean", self.root / "rust"], code=2, contains=["same executable"])
        for data in ['{"typo.json":"missing-main"}', '{"case.json":"typo"}',
                     '{"case.json":"missing-main","case.json":"wrong-field-prime"}']:
            self.expect.write_text(data)
            self.gate(expected=True, code=2)


if __name__ == "__main__":
    unittest.main()
