"""Verify cuobjdump's SASS/PTX inventories, including host-only and prebuilt-library cases."""

import json
import re
import subprocess
import sys
from pathlib import Path


def architectures(text: str) -> tuple[set[str], set[str]]:
    sections = {"elf": set(), "ptx": set()}
    section = None
    for line in text.splitlines():
        header = re.match(r"^Fatbin (elf|ptx) code:", line)
        if header:
            section = header[1]
        arch = re.match(r"^arch = sm_(\w+)$", line)
        if section and arch:
            sections[section].add(arch[1])
    return sections["elf"], sections["ptx"]


def check_dump(
    program: str, dump: subprocess.CompletedProcess, expected: set[str], prebuilt: bool
) -> None:
    if "does not contain device code" in dump.stderr:
        if prebuilt:
            raise ValueError(
                f"{program}: prebuilt-device-code declaration is stale; contains no device code"
            )
        print(
            f"{program} contains no device code, as cuobjdump reports; nothing to check"
        )
        return
    if dump.returncode:
        raise ValueError(
            f"cuobjdump exited with status {dump.returncode} on {program}: {dump.stderr}"
        )
    sass, ptx = architectures(dump.stdout)
    if not sass and not ptx:
        raise ValueError(
            f"cuobjdump succeeded on {program} but reported no readable architectures"
        )
    print(f"{program} embeds SASS for: {sorted(sass)}; PTX for: {sorted(ptx)}")
    if prebuilt:
        print(
            f"{program} takes its device code from a prebuilt library; not compared against {sorted(expected)}"
        )
        return
    differences = {
        "missing SASS (PTX alone is insufficient)": expected - sass,
        "unexpected SASS": sass - expected,
        "unexpected PTX": ptx - expected,
    }
    errors = [
        f"{kind}: {sorted(values)}" for kind, values in differences.items() if values
    ]
    if errors:
        raise ValueError(
            f"{program}: {'; '.join(errors)}; requested {sorted(expected)}"
        )


def main(settings: str, output: str, source: str) -> None:
    config = json.loads(settings)
    expected, prebuilt = set(config["expected"]), set(config["prebuilt"])
    out = Path(output)
    programs = sorted(path.name for path in (out / "bin").iterdir())
    unknown = prebuilt - set(programs)
    if unknown:
        raise ValueError(
            f"prebuilt-device-code declarations name absent executables: {sorted(unknown)}"
        )
    for program in programs:
        dump = subprocess.run(
            ["cuobjdump", str(out / "bin" / program)],
            capture_output=True,
            text=True,
            check=False,
        )
        check_dump(program, dump, expected, program in prebuilt)
    # Hand-written nvcc commands can hide LTO IR in C arrays. Report this blind spot explicitly;
    # cuobjdump cannot certify the architecture of those embedded arrays.
    handwritten = []
    for path in sorted(Path(source).rglob("*")):
        if path.is_file() and (
            path.name == "CMakeLists.txt" or path.suffix == ".cmake"
        ):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"(^|\s)(-gencode|--generate-code)(\s|=)", line):
                    handwritten.append(f"{path}:{number}: {line}")
    if handwritten:
        print(
            "Device code compiled outside CMake's CUDA targets; cuobjdump does not certify these commands:"
        )
        print("\n".join(handwritten))


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (OSError, ValueError) as error:
        sys.exit(str(error))
