import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

if sys.argv[1:2] == ["--worker"]:
    def on_term(*_):
        Path("worker.signal").touch()
        raise SystemExit

    signal.signal(signal.SIGTERM, on_term)
    Path("worker.ready").touch()
    while True:
        signal.pause()
if sys.argv[1:2] == ["--orphan"]:
    Path("orphan.ready").touch()
    deadline = time.monotonic() + 15
    while not Path("orphan.release").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert (Path(sys.argv[2]) / "owned").is_file()
    Path("orphan.done").touch()
    sys.exit()

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
if run == "ignore-sigchld":
    assert signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN
    sys.exit()
if run == "self-terminate":
    previous = signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
    assert signal.SIGTERM in previous
    os.kill(os.getpid(), signal.SIGTERM)
    sys.exit("the vendor survived SIGTERM")
keep = Path(next(x.split("=", 1)[1] for x in sys.argv if x.startswith("--keep-dir=")))
(keep / "owned").touch(exist_ok=False)
if run == "second":
    worker = subprocess.Popen([sys.executable, "-P", __file__, "--worker"])

    def on_term(*_):
        try:
            worker.wait(timeout=2)
        except subprocess.TimeoutExpired:
            worker.kill()
            worker.wait()
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)

    signal.signal(signal.SIGTERM, on_term)
    while not Path("worker.ready").exists():
        time.sleep(0.01)
elif run == "crash":
    subprocess.Popen(
        [sys.executable, "-P", __file__, "--orphan", str(keep)], close_fds=False
    )
    while not Path("orphan.ready").exists():
        time.sleep(0.01)

Path(run + ".ready").write_text(str(keep))
while not Path(run + ".release").exists():
    time.sleep(0.01)
assert (keep / "owned").is_file()
