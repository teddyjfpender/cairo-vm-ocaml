"""Test corpus bookkeeping with artificial receipts and a copy-only adapter."""
import copy
import json
from pathlib import Path
import platform
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
from qualify_os_host import digest, qualify
from whole_os_job import measure


class SampleContract(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def write(self, name, value):
        path = self.root / name
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return {"path": name, "sha256": digest(path)}

    def test_receipt_and_measurement(self):
        host = self.write("host", """#!/usr/bin/env python3
import hashlib,json,pathlib,sys
req=json.load(sys.stdin)
data=pathlib.Path(req['witness']).read_bytes()
pathlib.Path(req['output']).write_bytes(data)
print(json.dumps(dict(schema=1,status='ok',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())))
""")
        (self.root/"host").chmod(0o755)
        sample = self.write("sample", "fixture only")
        source = self.write("raw", "fixture only")
        fold = dict(chain_id="SN_MAIN", number=123, block_hash="0xa", derived_root="0xb", header_root="0xb",
                    l1_anchor=dict(covered_through=125, transaction_hash="0x"+"1"*64,
                                   derived_root="0xc", contract_root="0xc"))
        case = dict(number=123, block_hash="0xa", state_root="0xb", categories=["cairo0-account","declare","revert","large-storage"],
                    declared_compiler_versions=["test1","test2"], source=source, witness=sample, rust_pie=sample,
                    fold_receipt=self.write("fold", fold))
        manifest = dict(schema=1, chain_id="SN_MAIN", cairo_vm="3.2.0", revision="1"*40, program=sample,cases=[case])

        def check(data):
            entry = self.write("manifest", data)
            return qualify(self.root/"manifest", entry["sha256"], self.root/"host")

        receipt = check(manifest)
        self.assertEqual(receipt["cases"][0]["sha256"], sample["sha256"])
        for key, val in [("rust_pie", host), ("state_root","0xe"), ("declared_compiler_versions",["test1"])]:
            altered = copy.deepcopy(manifest)
            altered["cases"][0][key] = val
            with self.assertRaises(ValueError):
                check(altered)
        with self.assertRaises(ValueError):
            qualify(self.root/"manifest", "0"*64, self.root/"host")
        if platform.system() == "Linux" and platform.machine() == "x86_64":
            # Test executable includes a copy/publication step. Values have no performance significance.
            executable = self.write("copy-job", '#!/bin/sh\ncp "$1" "$2"\n')
            (self.root/"copy-job").chmod(0o755)
            spec = dict(executable=executable, arguments=["{source}", "{output}", "{work}"])
            plan = dict(schema=1, chain_id="SN_MAIN", commands=dict(rust=spec, oxcairo=spec), hardware="fixture",
                        cache_policy="fixture", qualified_manifest_sha256=receipt["manifest_sha256"],
                        qualification=self.write("receipt",receipt), cases=[dict(number=123,source=source)])
            self.write("plan",plan)
            result = measure(self.root/"plan",2,1,10,self.root/"result")
            self.assertEqual(len(result["rows"]),4)
            self.assertEqual(result["cases"][0]["number"],123)


if __name__ == "__main__":
    unittest.main()
