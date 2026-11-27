"""Exercise empty, exact and partial chunks on both supported ZIP methods."""
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import zipfile


def main():
    executable = pathlib.Path(sys.argv[1]).resolve()
    with zipfile.ZipFile("rust4-bitwise.zip") as source:
        metadata = {k: source.read(k) for k in source.namelist() if k != "memory.bin"}
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "test.zip"
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            for cells in (0, 32768, 262145):
                with zipfile.ZipFile(path, "w", compression=method) as z:
                    for name, value in metadata.items():
                        z.writestr(name, value)
                    z.writestr("memory.bin", bytes(range(40)) * cells)
                subprocess.run([executable, "--stream", path], check=True)
            content = bytearray(path.read_bytes())
            central = content.index(b"PK\x01\x02")
            while True:
                name, extra, comment = struct.unpack_from("<HHH", content, central + 28)
                if content[central + 46:central + 46 + name] == b"memory.bin":
                    content[central + 16] ^= 1
                    break
                central += 46 + name + extra + comment
            path.write_bytes(content)
            subprocess.run([executable, "--invalid-stream", path], check=True)

        # Span an inflation buffer with consecutive cells in a real extra
        # segment. Move two cells across that boundary without changing
        # their contents or count: secure replay must still detect order.
        with zipfile.ZipFile("rust4-bitwise.zip") as source:
            memory = bytearray(source.read("memory.bin"))
        meta = json.loads(metadata["metadata.json"])
        extra = meta["extra_segments"]
        seg = (extra[-1] if extra else meta["ret_pc_segment"])["index"] + 1
        first = len(memory) // 40
        size = 32770 - first
        extra.append({"index": seg, "size": size})
        metadata["metadata.json"] = json.dumps(meta).encode()
        for offset in range(size):
            memory.extend(struct.pack("<Q", (1 << 63) | (seg << 47) | offset))
            memory.extend(bytes(32))
        for ordered in (True, False):
            if not ordered:
                boundary = 32768 * 40
                memory[boundary-40:boundary+40] = memory[boundary:boundary+40] + memory[boundary-40:boundary]
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
                for name, value in metadata.items():
                    z.writestr(name, value)
                z.writestr("memory.bin", memory)
            mode = "--ordered-replay" if ordered else "--unordered-replay"
            subprocess.run([executable, mode, path], check=True)


if __name__ == "__main__":
    main()
