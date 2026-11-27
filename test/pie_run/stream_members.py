"""Exercise empty, exact and partial chunks on both supported ZIP methods."""
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


if __name__ == "__main__":
    main()
