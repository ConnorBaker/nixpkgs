"""Run a CMake project's discovered executables with sparse invocation settings."""

import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


def relative(path: str) -> Path:
    result = Path(path)
    if not path or result.is_absolute() or ".." in result.parts:
        raise ValueError(f"path must stay inside the scratch directory: {path!r}")
    return result


def inventory(settings: dict) -> list[str]:
    sample = Path(settings["sample"])
    programs = sorted(path.name for path in (sample / "bin").iterdir())
    if not programs:
        raise ValueError("expected a nonempty executable inventory")
    for program in programs:
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+\-]*", program):
            raise ValueError(f"invalid executable name: {program!r}")
        binary = sample / "bin" / program
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"no executable named {program}")
    for program in settings.get("invocations", {}):
        if program not in programs:
            raise ValueError(f"invocation names absent executable {program}")
    return programs


def writable(path: Path) -> None:
    # Store inputs arrive read-only. Make copies writable both for the sample and for cleanup.
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    if path.is_dir():
        for child in path.iterdir():
            writable(child)


@contextmanager
def prepare(invocation: dict):
    """Prepare and clean up the same fresh working tree for preflight and execution."""
    with tempfile.TemporaryDirectory(prefix="cuda-sample-") as directory:
        root = Path(directory).resolve()
        for path, source in invocation.get("dataFiles", {}).items():
            if not Path(source).is_absolute():
                raise ValueError(
                    f"staged source must be an explicit absolute path: {source!r}"
                )
            destination = root / relative(path)
            print(f"staging {source} as {path}", flush=True)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if Path(source).is_dir():
                shutil.copytree(source, destination, dirs_exist_ok=True)
            else:
                shutil.copy2(source, destination)
            writable(destination)
        outputs = [
            root / relative(path) for path in invocation.get("expectedOutputs", [])
        ]
        for output in outputs:
            output.parent.mkdir(parents=True, exist_ok=True)
        work = root / relative(invocation.get("workSubdir", "."))
        work.mkdir(parents=True, exist_ok=True)
        for output in outputs:
            if output.exists() or output.is_symlink():
                raise ValueError(
                    f"expected output exists before execution: {output.relative_to(root)}"
                )
        yield root, work, outputs


def validate(settings: dict) -> list[str]:
    programs = inventory(settings)
    # Disabled invocations remain declarations worth checking, but no program is executed.
    for invocation in settings.get("invocations", {}).values():
        with prepare(invocation):
            pass
    return programs


def run(settings: dict, program: str, invocation: dict) -> None:
    with prepare(invocation) as (root, work, outputs):
        command = [
            str(Path(settings["sample"]) / "bin" / program),
            *invocation.get("args", []),
        ]
        env = os.environ | {"PATH": settings["path"]}
        env.update(invocation.get("runtimeEnv") or {})
        print(f"running {shlex.join(command)}", flush=True)
        subprocess.run(command, cwd=work, env=env, check=True)
        missing = [
            str(path.relative_to(root))
            for path in outputs
            if not path.resolve().is_relative_to(root)
            or not path.is_file()
            or not path.stat().st_size
        ]
        if missing:
            raise ValueError(
                f"{program} exited successfully without writing: {', '.join(missing)}"
            )
        if outputs:
            print(f"wrote {len(outputs)} expected output(s)", flush=True)


def main(args: list[str]) -> int:
    settings = json.loads(Path(args[0]).read_text())
    if len(args) > 2:
        raise ValueError("usage: tester [program|--list]")
    selected = args[1] if len(args) == 2 else None
    if selected == "--validate":
        validate(settings)
        return 0
    programs = inventory(settings)
    if selected == "--list":
        print("\n".join(programs))
        return 0
    if selected is not None:
        if selected not in programs:
            raise ValueError(f"unknown executable: {selected}")
        programs = [selected]
    ran = failed = 0
    for program in programs:
        invocation = settings.get("invocations", {}).get(program, {})
        if not invocation.get("available", True):
            print(f"skipping {program}: {invocation['reason']}", flush=True)
            if selected is not None:
                return 1
            continue
        ran += 1
        try:
            run(settings, program, invocation)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f"{program} failed: {error}", file=sys.stderr, flush=True)
            failed += 1
    print(f"ran {ran} executable(s); {failed} failed", flush=True)
    return int(ran == 0 or failed != 0)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
