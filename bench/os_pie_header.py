"""Read the fixed Starknet OS public-output header from a Cairo VM 3.2 PIE."""
import io
import json
import struct
import zipfile
import zlib

PRIME = (1 << 251) + 17 * (1 << 192) + 1
RECORD = struct.Struct("<Q32s")
OFFSET_BASE = 1 << 47
HEADER_WORDS = 10
MAX_METADATA = 8 << 20
MAX_MEMORY = 8 << 30


class ArchiveReader(io.BufferedReader):
    """Bound zipfile's eager central-directory read as well as member reads."""
    def read(self, size=-1):
        if size < 0:
            pos = self.tell()
            size = self.seek(0, io.SEEK_END) - pos
            self.seek(pos)
        if size > 256 << 10:
            raise ValueError("PIE directory or read exceeds the bounded reader")
        return super().read(size)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate PIE metadata key")
        result[key] = value
    return result


def output_header(path):
    try:
        with ArchiveReader(io.FileIO(path, "r")) as source, zipfile.ZipFile(source) as pie:
            entries = pie.infolist()
            if len(entries) != len({entry.filename for entry in entries}):
                raise ValueError("duplicate PIE archive member")
            meta, memory = (pie.getinfo(key) for key in ("metadata.json", "memory.bin"))
            if any(e.flag_bits & 1 or e.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                   for e in (meta, memory)):
                raise ValueError("unsupported PIE member compression")
            if meta.file_size > MAX_METADATA or memory.file_size > MAX_MEMORY or memory.file_size % RECORD.size:
                raise ValueError("invalid PIE member size")
            with pie.open(meta) as member:
                raw_metadata = b"".join(iter(lambda: member.read(64 << 10), b""))
            if len(raw_metadata) != meta.file_size:
                raise ValueError("truncated PIE metadata")
            metadata = json.loads(raw_metadata, object_pairs_hook=unique_object)
            builtins = metadata["program"]["builtins"]
            output = metadata["builtin_segments"]["output"]
            index, size = output["index"], output["size"]
            if not (isinstance(builtins, list) and builtins.count("output") == 1
                    and type(index) is int and index == 2 + builtins.index("output") and index < 1 << 16
                    and type(size) is int and HEADER_WORDS <= size <= OFFSET_BASE):
                raise ValueError("invalid PIE output builtin segment")
            # cairo-vm-3.2.0 encodes an address as the high tag plus segment*2^47 plus offset.
            base = (1 << 63) + index * OFFSET_BASE
            words = [None] * HEADER_WORDS
            memory_bytes = 0
            with pie.open(memory) as member:
                for chunk in iter(lambda: member.read(2048 * RECORD.size), b""):
                    memory_bytes += len(chunk)
                    for address, raw in RECORD.iter_unpack(chunk):
                        if base <= address < base + HEADER_WORDS:
                            offset = address - base
                            word = int.from_bytes(raw, "little")
                            if words[offset] is not None or word >= PRIME:
                                raise ValueError("duplicate or non-felt PIE output header cell")
                            words[offset] = word
            if memory_bytes != memory.file_size:
                raise ValueError("truncated PIE memory")
            if None in words or words[8] not in (0, 1) or words[9] not in (0, 1):
                raise ValueError("missing or invalid PIE output header")
            # OsOutput::try_from_output_iter at both supported sequencer revisions.
            return words[1], words[3], words[5]
    except (KeyError, TypeError, EOFError, RecursionError, struct.error, zlib.error, zipfile.BadZipFile) as exc:
        raise ValueError("invalid PIE output header or archive") from exc
