"""Interrupt the packaged supervisor at explicit before- and after-execution checkpoints."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise RuntimeError("checkpoint deadline expired")


def check(binary, program, witness):
    binary = binary.absolute()
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        host = work / "oxcairo-os-host"
        shutil.copy2(binary, host)
        cli = binary.with_name("cairo-vm-cli")
        shim = work / "cairo-vm-cli"
        ready = work / "checkpoint"
        output = work / "result.zip"
        request = json.dumps(dict(schema=1, revision="ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45",
                                  program=str(program), witness=str(witness), output=str(output))).encode()

        def invoke():
            return subprocess.run([binary, "v1"], input=request, capture_output=True, timeout=30)

        successful = invoke()
        assert successful.returncode == 0, successful.stdout
        expected = output.read_bytes()
        for phase in ("before", "after"):
            output.write_bytes(b"prior committed result")
            # Instrument only this private test installation. The shipped native binary executes the job.
            # A post-execution interruption happens after the worker wrote the complete staging ZIP.
            shim.write_text("#!" + sys.executable + "\nimport pathlib, subprocess, sys, time\n"
                            + (f"subprocess.run([{str(cli)!r}, *sys.argv[1:]], check=True)\n" if phase == "after" else "")
                            + f"pathlib.Path({str(ready)!r}).touch()\ntime.sleep(10)\n")
            shim.chmod(0o755)
            with subprocess.Popen([host, "v1"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
                proc.stdin.write(request)
                proc.stdin.close()
                wait_until(ready.exists, 10)
                os.kill(proc.pid, signal.SIGKILL)
                proc.wait()
            assert output.read_bytes() == b"prior committed result"
            ready.unlink()
            def retry():
                completed = invoke()
                if completed.returncode == 26:
                    return False
                assert completed.returncode == 0, completed.stdout
                return True
            wait_until(retry, 10)
            assert output.read_bytes() == expected
            assert not (work / ".result.zip.oxcairo-stage").exists()


if __name__ == "__main__":
    check(*(Path(arg).absolute() for arg in sys.argv[1:]))
