"""Write the driver's selection manifest and optionally prepare its private companion lookups."""

import argparse
import json
import os
from pathlib import Path
import re
import sys

from elftools.elf.elffile import ELFFile

from elf_edit import imports_glibc_dlopen, wrap_lookup


def supported_branches(elf):
    section = elf.get_section_by_name(".note.cuda.fwd_compatibility")
    if section is None or section["sh_type"] != "SHT_NOTE":
        return []
    notes = list(section.iter_notes())
    if len(notes) != 1:
        return []
    note = notes[0]
    if note["n_name"] != "NVIDIA Corporation" or note["n_type"] != 0:
        return []
    try:
        policy = json.loads(note["n_desc"].rstrip(b"\0"))
    except (UnicodeDecodeError, ValueError):
        return []
    if not isinstance(policy, dict) or type(policy.get("format")) is not int or policy["format"] != 1:
        return []
    branches = policy.get("driver")
    if not isinstance(branches, list) or not all(type(b) is int and 0 < b <= 2**31 - 1 for b in branches):
        return []
    return sorted(set(branches))


def write_manifest(out, platform, wrap):
    directory = out / "compat"
    driver = (directory / "libcuda.so.1").resolve(strict=True)
    match = re.fullmatch(r"libcuda\.so\.([0-9]+)\.([0-9]+)(?:\.([0-9]+))?", driver.name)
    if driver.parent != directory or not driver.is_file() or match is None:
        raise ValueError(f"unexpected compatibility driver path: {driver}")
    version = ".".join(str(int(part)) for part in match.groups("0"))

    companions = []
    with driver.open("rb") as f:
        elf = ELFFile(f)
        dynamic = elf.get_section_by_name(".dynamic")
        if dynamic is None or [tag.soname for tag in dynamic.iter_tags("DT_SONAME")] != ["libcuda.so.1"]:
            raise ValueError(f"unexpected SONAME for {driver}")
        # The legacy Tegra libcuda.so.1.1 filename describes an ABI, not the driver release.
        branches = [] if platform == "linux-aarch64" else supported_branches(elf)
        if branches and wrap and imports_glibc_dlopen(elf):
            companions = sorted(
                p for p in directory.iterdir()
                if re.fullmatch(r"lib.*\.so(?:\..*)?", p.name) and p.is_file() and not p.samefile(driver)
            )
    if not branches:
        print(f"{driver}: no supported automatic selection policy for {platform}", file=sys.stderr)
    support = out / "nix-support"
    support.mkdir(exist_ok=True)
    manifest = support / "nix-cuda-compat"
    manifest.write_text(
        f"{version}\n{' '.join(map(str, branches))}\n{driver}\n", encoding="ascii"
    )

    if companions:
        wrap_lookup(driver, *wrap)
        for p in companions:
            # The Rust lookup embeds NUL-terminated alias/canonical-path pairs.
            sys.stdout.buffer.write(os.fsencode(p.name) + b"\0" + os.fsencode(p.resolve(strict=True)) + b"\0")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform")
    parser.add_argument("output", type=Path)
    parser.add_argument("--wrap", nargs=3, metavar=("PATCHELF", "HELPER", "SYMBOL"))
    args = parser.parse_args()
    write_manifest(args.output, args.platform, args.wrap)
