"""Check scratch directory ownership and cancellation without running NVIDIA's compiler."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        driver = work / "nvcc"
        shutil.copy(sys.argv[1], driver)
        fake = work / ".nvcc-wrapped"
        fake.write_text(
            f"#!{sys.executable}\n"
            """
import json, os, pathlib, signal, subprocess, sys, time

run = os.environ["RUN"]
if run == "arguments":
    print(json.dumps(sys.argv[1:]))
    sys.exit()
if run == "closed-stdout":
    try:
        os.fstat(1)
    except OSError:
        sys.exit()
    sys.exit("the wrapper reopened stdout")
if run == "self-terminate":
    previous = signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
    assert signal.SIGTERM in previous
    os.kill(os.getpid(), signal.SIGTERM)
    sys.exit("the vendor survived SIGTERM")
keep = pathlib.Path(next(x.split("=", 1)[1] for x in sys.argv if x.startswith("--keep-dir=")))
(keep / "owned").touch(exist_ok=False)
if run == "second":
    worker = subprocess.Popen([sys.executable, "-c", '''
import pathlib, signal

def on_term(*_):
    pathlib.Path("worker.signal").touch()
    raise SystemExit

signal.signal(signal.SIGTERM, on_term)
pathlib.Path("worker.ready").touch()
while True:
    signal.pause()
'''])

    def on_term(*_):
        try:
            worker.wait(timeout=2)
        except subprocess.TimeoutExpired:
            worker.kill()
            worker.wait()
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)

    signal.signal(signal.SIGTERM, on_term)
    while not pathlib.Path("worker.ready").exists():
        time.sleep(0.01)
elif run == "crash":
    subprocess.Popen([sys.executable, "-c", '''
import pathlib, sys, time

pathlib.Path("orphan.ready").touch()
deadline = time.monotonic() + 15
while not pathlib.Path("orphan.release").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
assert (pathlib.Path(sys.argv[1]) / "owned").is_file()
pathlib.Path("orphan.done").touch()
''', str(keep)], close_fds=False)
    while not pathlib.Path("orphan.ready").exists():
        time.sleep(0.01)

pathlib.Path(run + ".ready").write_text(str(keep))
while not pathlib.Path(run + ".release").exists():
    time.sleep(0.01)
assert (keep / "owned").is_file()
"""
        )
        fake.chmod(0o755)
        env = {**os.environ, "TMPDIR": directory}
        env.pop("NVCC_PREPEND_FLAGS", None)
        env.pop("NVCC_APPEND_FLAGS", None)
        compile_args = ["-c", "example.cu", "-o", "example.o"]

        # Exercise exec and supervised execution with an originally closed descriptor.
        for args in (["--version"], compile_args):
            subprocess.run(
                [driver, *args],
                cwd=work,
                env={**env, "RUN": "closed-stdout"},
                preexec_fn=lambda: os.close(1),
                check=True,
                timeout=10,
            )

        # A vendor can unblock an inherited signal and terminate from it.
        terminated = subprocess.run(
            [driver, *compile_args],
            cwd=work,
            env={**env, "RUN": "self-terminate"},
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM}),
            timeout=10,
        )
        assert terminated.returncode == -signal.SIGTERM, terminated.returncode
        assert not list(work.glob("nvcc-keep-*"))

        def start(name):
            return subprocess.Popen(
                [driver, *compile_args],
                cwd=work,
                env={**env, "RUN": name},
                start_new_session=True,
            )

        def ready(name, process):
            marker = work / f"{name}.ready"
            deadline = time.monotonic() + 10
            while not marker.exists():
                assert process.poll() is None and time.monotonic() < deadline, name
                time.sleep(0.01)
            return marker.read_text()

        processes = []
        try:
            first = start("first")
            processes.append(first)
            first_path = ready("first", first)
            second = start("second")
            processes.append(second)
            time.sleep(0.2)
            assert second.poll() is None and not (work / "second.ready").exists()
            (work / "first.release").touch()
            assert first.wait(timeout=10) == 0
            assert ready("second", second) == first_path
            second.terminate()
            assert second.wait(timeout=10) == -signal.SIGTERM
            assert (work / "worker.signal").exists()
            assert not list(work.glob("nvcc-keep-*"))

            crash = start("crash")
            processes.append(crash)
            assert ready("crash", crash) == first_path
            crash.kill()
            assert crash.wait(timeout=10) == -signal.SIGKILL
            recovered = start("recovered")
            processes.append(recovered)
            time.sleep(0.2)
            assert recovered.poll() is None and not (work / "recovered.ready").exists()
            (work / "orphan.release").touch()
            assert ready("recovered", recovered) == first_path
            assert (work / "orphan.done").exists()
            (work / "recovered.release").touch()
            assert recovered.wait(timeout=10) == 0
            assert not list(work.glob("nvcc-keep-*"))

            # A nonempty directory without the wrapper's marker belongs to the caller.
            keep = Path(first_path)
            keep.mkdir(mode=0o700)
            (keep / "unowned").write_text("keep this")
            arguments_env = {**env, "RUN": "arguments"}

            def received(args):
                return json.loads(subprocess.check_output([driver, *args], cwd=work, env=arguments_env, timeout=10))

            assert "--keep" not in received(compile_args)
            assert (keep / "unowned").read_text() == "keep this"

            sources = ["-c", "first.cu", "second.cu"]
            actual = received(sources)
            assert actual[-len(sources):] == sources
            assert not any(arg.startswith("--frandom-seed") for arg in actual)
        finally:
            (work / "orphan.release").touch()
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()

        # Bash preserves the inherited disposition. Python installs SIG_IGN at startup.
        bash = shutil.which("bash")
        assert bash is not None
        fake.write_text(f"#!{bash}\nkill -s PIPE $$\nexit 42\n")
        for args in (["--version"], compile_args):
            for restore, status in ((True, -signal.SIGPIPE), (False, 42)):
                result = subprocess.run(
                    [driver, *args],
                    cwd=work,
                    env=env,
                    restore_signals=restore,
                    timeout=10,
                )
                assert result.returncode == status, result.returncode


if __name__ == "__main__":
    main()
