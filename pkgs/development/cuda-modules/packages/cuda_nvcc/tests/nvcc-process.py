"""Verify that retrying a killed build waits for the original host compiler."""

from contextlib import suppress
import errno
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def wait_for(process, predicate):
    deadline = time.monotonic() + 30
    while not (result := predicate()):
        assert process.poll() is None, f"nvcc exited early: {process.returncode}"
        assert time.monotonic() < deadline, "timed out waiting for nvcc"
        time.sleep(0.01)
    return result


def open_writer(gate):
    try:
        return os.fdopen(os.open(gate, os.O_WRONLY | os.O_NONBLOCK), "wb")
    except OSError as error:
        if error.errno != errno.ENXIO:
            raise
        return None


def waiting_on_scratch(process, scratch):
    descriptors = Path(f"/proc/{process.pid}/fd")
    # An exec can briefly make these links unreadable while credentials change.
    with suppress(FileNotFoundError, PermissionError):
        for fd in descriptors.iterdir():
            with suppress(FileNotFoundError, PermissionError):
                if os.readlink(fd) == str(scratch):
                    return True
    return False


def main():
    nvcc, arch, *headers = sys.argv[1:]
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory).resolve()
        (work / "kernel.cu").write_text("__global__ void kernel() {}\n")
        header = work / "include.h"
        empty = work / "empty.h"
        empty.touch()
        os.mkfifo(header)
        command = [nvcc, f"-arch={arch}", "-c", "kernel.cu", *headers, "-include", str(header), "-o", "kernel.o"]
        env = {**os.environ, "TMPDIR": str(work)}
        for variable in ("NVCC_PREPEND_FLAGS", "NVCC_APPEND_FLAGS"):
            env.pop(variable, None)

        processes = []
        try:
            first = subprocess.Popen(command, cwd=work, env=env, start_new_session=True)
            processes.append(first)
            # The actual host preprocessor is reading this header and cannot
            # finish until the writer closes it.
            with wait_for(first, lambda: open_writer(header)):
                (scratch,) = work.glob("nvcc-keep-*")
                first.kill()
                assert first.wait(timeout=30) == -signal.SIGKILL

                # After the wrapper has exited, only its vendor descendants
                # can still hold the exclusive scratch-directory lock.
                fd = os.open(scratch, os.O_DIRECTORY)
                try:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        pass
                    else:
                        raise AssertionError("host compiler lost the scratch lock")
                finally:
                    os.close(fd)

                retry = subprocess.Popen(command, cwd=work, env=env, start_new_session=True)
                processes.append(retry)
                wait_for(retry, lambda: waiting_on_scratch(retry, scratch))
                assert not Path(f"/proc/{retry.pid}/task/{retry.pid}/children").read_text().strip()
                # Future preprocessing passes see a regular file. The old reader
                # still has the FIFO open and is released as this block exits.
                empty.replace(header)

            assert retry.wait(timeout=30) == 0, retry.returncode
            assert (work / "kernel.o").stat().st_size > 0
            assert not list(work.glob("nvcc-keep-*"))
        finally:
            for process in processes:
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    main()
