"""Record which option spellings consume a separate argument in each binary."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import subprocess
import sys


def generate(bin_dir, emulator):
    env = {**os.environ, "LC_ALL": "C"}
    for variable in ("NVCC_PREPEND_FLAGS", "NVCC_APPEND_FLAGS"):
        env.pop(variable, None)

    for tool in ("nvcc", "ptxas"):
        installed = bin_dir / tool
        vendor = bin_dir / f".{tool}-wrapped"
        # nvcc uses argv[0] to locate its profile.
        command = [*emulator, "-0", installed, vendor] if emulator else [installed]
        executable = command[0] if emulator else vendor

        def invoke(option):
            result = subprocess.run(
                [*command, option],
                executable=executable,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
            )
            if result.returncode < 0:
                raise RuntimeError(f"{tool}: {option!r} terminated by signal {-result.returncode}")
            return result

        def takes_operand(option):
            result = invoke(option)
            return result.returncode != 0 and b"argument expected after" in result.stdout

        doc = invoke(b"--help")
        flags = set()
        for line in doc.stdout.splitlines():
            if heading := re.match(rb"^(--[\w-]+)", line):
                flags.add(heading[1])
                if alias := re.search(rb"\((-[-\w]+)\)\s*$", line):
                    flags.add(alias[1])
        with ThreadPoolExecutor(max_workers=8) as workers:
            ordered = sorted(flags)
            arity = dict(zip(ordered, workers.map(takes_operand, ordered), strict=True))

        required = {flag for flag, takes_value in arity.items() if takes_value}
        if doc.returncode or not {b"--output-file", b"-o", b"--options-file", b"-optf"} <= required:
            raise RuntimeError(f"{tool}: could not recognize help output or missing-operand diagnostics")
        (bin_dir / f".{tool}.operands").write_bytes(
            b"".join((b"1" if takes_value else b"0") + flag + b"\n" for flag, takes_value in arity.items())
        )
        print(f"{tool}: {len(required)} required operands from {len(flags)} option spellings")


if __name__ == "__main__":
    generate(Path(sys.argv[1]), sys.argv[2:])
