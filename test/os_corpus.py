"""Test corpus bookkeeping with artificial receipts and a copy-only adapter."""
import copy
import json
from pathlib import Path
import platform
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
from fold_receipt import receipt as from_fold
from qualify_os_host import digest, qualify
from os_pie_header import MAX_METADATA, output_header
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

    def pie(self, words, *, index=2, size=10, extra=b"", omit=(), reverse=False):
        path = self.root / "reference.zip"
        meta = dict(program=dict(builtins=["output"]), builtin_segments=dict(output=dict(index=index, size=size)))
        base = (1 << 63) + (index << 47)
        cells = [(base + i, word) for i, word in enumerate(words) if i not in omit]
        # A second segment can contain the same offsets; they carry no OS output.
        cells.append((1 << 63, 99))
        if reverse:
            cells.reverse()
        memory = b"".join(struct.pack("<Q", address) + word.to_bytes(32, "little")
                          for address, word in cells) + extra
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("metadata.json", json.dumps(meta))
            archive.writestr("memory.bin", memory)
        return {"path": path.name, "sha256": digest(path)}

    def test_bounded_public_header(self):
        words = [0, 11, 122, 123, 9, 10, 0, 1, 0, 1]
        self.pie(words, reverse=True)
        self.assertEqual(output_header(self.root/"reference.zip"), (11, 123, 10))
        for kwargs in [dict(index=3), dict(size=5), dict(extra=b"short"), dict(omit=(1,)),
                       dict(extra=struct.pack("<Q", (1 << 63) + (2 << 47) + 1) + bytes(32))]:
            self.pie(words, **kwargs)
            with self.assertRaises(ValueError):
                output_header(self.root/"reference.zip")
        for offset, value in [(1, 1 << 255), (5, (1 << 251) + 17 * (1 << 192) + 1), (8, 2)]:
            bad = words.copy()
            bad[offset] = value
            self.pie(bad)
            with self.assertRaises(ValueError):
                output_header(self.root/"reference.zip")

    def test_rejects_oversized_or_ambiguous_members(self):
        path = self.root / "reference.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("metadata.json", b" " * (MAX_METADATA + 1))
            archive.writestr("memory.bin", b"")
        with self.assertRaisesRegex(ValueError, "member size"):
            output_header(path)
        self.pie([0] * 10)
        with zipfile.ZipFile(path, "a") as archive, self.assertWarns(UserWarning):
            archive.writestr("memory.bin", b"")
        with self.assertRaisesRegex(ValueError, "duplicate PIE archive"):
            output_header(path)

    def test_original_fold_evidence(self):
        rows = [
            dict(first=0,last=12,blocks=13,check="header",root="0x11"),
            dict(first=13,last=15,blocks=3,check="header+l1",root="0x22")]
        self.write("header",dict(block_number=12,block_hash="0xa",state_root="0x11"))
        self.write("anchors",dict(anchors=[dict(block_number=15,global_root="0x22",block_hash="0xc",tx_hash="0x"+"1"*64)]))
        def read():
            self.write("rows", "\n".join(json.dumps(row) for row in rows))
            return from_fold(self.root/"rows",self.root/"header",self.root/"anchors",15)
        self.assertEqual(read()["l1_anchor"]["covered_through"],15)
        rows[1]["root"] = "0x23"
        with self.assertRaisesRegex(ValueError, "anchor root mismatch"):
            read()
        rows[1]["first"] = 14
        with self.assertRaisesRegex(ValueError, "non-contiguous"):
            read()

    def test_receipt_and_measurement(self):
        host = self.write("host", """#!/usr/bin/env python3
import hashlib,json,pathlib,sys
req=json.load(sys.stdin)
data=pathlib.Path(__file__).with_name('reference.zip').read_bytes()
pathlib.Path(req['output']).write_bytes(data)
print(json.dumps(dict(schema=1,status='ok',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())))
""")
        (self.root/"host").chmod(0o755)
        document = dict(os_hints_config=dict(chain_info=dict(chain_id=hex(int.from_bytes(b"SN_MAIN", "big")))),
                        os_input=dict(os_block_inputs=[dict(block_info=dict(block_number=123), new_block_hash="0xa")]))
        sample = self.write("sample", document)
        pie = self.pie([0, 11, 122, 123, 9, 10, 0, 1, 0, 1])
        original_bytes = (self.root/"reference.zip").read_bytes()
        source = dict(pie)
        fold = dict(chain_id="SN_MAIN", number=123, block_hash="0xa", derived_root="0xb", header_root="0xb",
                    l1_anchor=dict(covered_through=125, transaction_hash="0x"+"1"*64,
                                   derived_root="0xc", contract_root="0xc"))
        case = dict(number=123, block_hash="0xa", state_root="0xb", categories=["cairo0-account","declare","revert","large-storage"],
                    declared_compiler_versions=["test1","test2"], source=source, witness=sample, rust_pie=pie,
                    fold_receipt=self.write("fold", fold))
        manifest = dict(schema=1, chain_id="SN_MAIN", cairo_vm="3.2.0", revision="1"*40, program=sample,cases=[case])

        def check(data):
            entry = self.write("manifest", data)
            return qualify(self.root/"manifest", entry["sha256"], self.root/"host")

        receipt = check(manifest)
        self.assertEqual(receipt["cases"][0]["sha256"], pie["sha256"])
        self.assertEqual(receipt["cases"][0]["state_root"], "0xb")
        # Both engines publish the same ZIP, but the authenticated independent
        # fold and manifest may identify a different root.
        wrong = copy.deepcopy(manifest)
        wrong["cases"][0]["state_root"] = "0xe"
        changed_fold = dict(fold, derived_root="0xe", header_root="0xe")
        wrong["cases"][0]["fold_receipt"] = self.write("other-fold", changed_fold)
        with self.assertRaisesRegex(ValueError, "PIE public output"):
            check(wrong)
        for offset in [3, 5]:
            words = [0, 11, 122, 123, 9, 10, 0, 1, 0, 1]
            words[offset] += 1
            changed = copy.deepcopy(manifest)
            changed["cases"][0]["rust_pie"] = self.pie(words)
            changed["cases"][0]["source"] = changed["cases"][0]["rust_pie"]
            with self.assertRaisesRegex(ValueError, "PIE public output"):
                check(changed)
        # Restore the exact original ZIP bytes for the whole-job copy observer.
        (self.root/"reference.zip").write_bytes(original_bytes)
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
