"""Exercise the distributed host command and its typed process responses."""

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("host", "program", "witness"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    command = [str(args.host.absolute()), "v1"]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        output = root / "output.zip"
        job = dict(schema=1, revision="ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45",
                   program=str(args.program.absolute()), witness=str(args.witness.absolute()), output=str(output))

        def run(request, *, code=0, kind=None, environment=None):
            raw = request if isinstance(request, bytes) else json.dumps(request).encode()
            proc = subprocess.run(command, input=raw, capture_output=True, timeout=45, env=environment)
            reply = json.loads(proc.stdout)
            assert proc.returncode == code and reply["schema"] == 1, (proc.returncode, reply)
            assert reply["status"] == ("ok" if code == 0 else "rejected"), reply
            if kind:
                assert reply["code"] == kind, reply
            return reply

        ok = run(job)
        before = output.read_bytes()
        assert ok["bytes"] == len(before) and ok["sha256"] == hashlib.sha256(before).hexdigest()
        with zipfile.ZipFile(output) as pie:
            steps = json.loads(pie.read("execution_resources.json"))["n_steps"]
            expected = json.loads(args.witness.with_suffix(".sha256.json").read_text())
            assert expected == {i.filename: hashlib.sha256(pie.read(i)).hexdigest() for i in pie.infolist()}
        run(job | {"limits": {"steps": steps}})
        for limit, value, code, kind in [
            ("steps", steps - 1, 20, "step_limit"), ("memory_bytes", 1, 21, "memory_limit"),
            ("wall_ms", 1, 22, "wall_limit"), ("output_bytes", 32, 23, "output_limit"),
            ("open_files", 7, 24, "file_limit"), ("steps", True, 2, "invalid_request"),
        ]:
            run(job | {"limits": {limit: value}}, code=code, kind=kind)
        for malformed in [b"", b"{}", b'{"schema":1,"schema":1}', b"x" * 65537, json.dumps(job).encode()+b'\n{}']:
            run(malformed, code=2, kind="invalid_request")
        run(job | {"revision": "unknown"}, code=3, kind="unknown_revision")
        run(job | {"program": job["witness"]}, code=4, kind="program_mismatch")
        run(job | {"output": job["witness"]}, code=2, kind="invalid_request")
        invalid = root / "input.json"
        invalid.write_bytes(b'{"os_input":')
        run(job | {"witness": str(invalid)}, code=5, kind="invalid_input")
        fifo = root / "input.pipe"
        os.mkfifo(fifo)
        run(job | {"witness": str(fifo)}, code=5, kind="invalid_input")
        with (root / ".output.zip.oxcairo.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            run(job, code=26, kind="busy")
        assert output.read_bytes() == before
        profile = root / "profile.json"
        profile.write_text(json.dumps(dict(revision="1" * 40, program_sha256=hashlib.sha256(args.program.read_bytes()).hexdigest())))
        run(job | {"revision": "1" * 40}, environment=os.environ | {"OXCAIRO_OS_PROFILE": str(profile)})
        targets = [root / ("worker%d.zip" % i) for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(run, [job | {"output": str(path)} for path in targets]))
        assert all(path.read_bytes() == before for path in targets)

        # Interrupt after the worker exists and before its compiler snapshot is complete.
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as host:
            host.stdin.write(json.dumps(job).encode())
            host.stdin.close()
            stage = root / ".output.zip.oxcairo-stage"
            deadline = time.monotonic() + 5
            while not (stage / "error").exists() and time.monotonic() < deadline:
                time.sleep(0.001)
            assert (stage / "error").exists()
            host.send_signal(signal.SIGKILL)
            host.wait()
        for _ in range(200):
            try:
                result = run(job)
                break
            except AssertionError:
                # A surviving worker can briefly retain the lock on macOS.
                if not stage.exists():
                    raise
                time.sleep(0.05)
        else:
            raise AssertionError("interrupted output did not become available")
        assert result["sha256"] == ok["sha256"] and not stage.exists()
    print("Installed OS host passed process, artifact, limit, concurrency and restart checks")


if __name__ == "__main__":
    main()
