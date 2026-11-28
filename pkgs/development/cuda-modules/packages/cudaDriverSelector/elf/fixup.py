"""Attach the CUDA lookup policy only to ELF objects that can use it."""

import argparse
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

from elftools.common.exceptions import ELFError
from elftools.elf.elffile import ELFFile

from elf_edit import edit_elf, imports_glibc_dlopen, wrap_lookup


class Policy(NamedTuple):
    manifest: str
    auditor: str
    lookup: str
    symbol: str
    interpreter: str


def abi(elf):
    return elf["e_machine"], elf.elfclass, elf.little_endian


def write_candidates(output, candidates):
    # buildEnv leaves nix-support out of profiles. Keep each output's policy
    # with that output, even when many packages contribute to the same bin/.
    support = output / "nix-support"
    if support.is_symlink():
        raise ValueError(f"cannot write CUDA policy through symlink {support}")
    support.mkdir(exist_ok=True)
    destination = support / "cuda-driver-selection"
    previous = destination.read_text() if destination.is_file() else ""
    paths = set(previous.splitlines()).union(map(os.path.realpath, candidates))
    content = "".join(path + "\n" for path in sorted(paths) if path)
    if content != previous or destination.is_symlink():
        with tempfile.TemporaryDirectory(dir=support) as tmp:
            new = Path(tmp) / "candidates"
            new.write_text(content)
            new.replace(destination)


def dynamic_bytes(dynamic, offset, size):
    _, table = dynamic.get_table_offset("DT_STRTAB")
    dynamic.stream.seek(table + offset)
    return dynamic.stream.read(size)


def add_audit(path, auditor, patchelf, dynamic, tags):
    """Append to glibc's effective (last) DT_AUDIT list, if present."""
    auditor = os.fsencode(auditor)
    audits = [tag.entry.d_val for tag in tags if tag.entry.d_tag == "DT_AUDIT"]
    old_size = next(tag.entry.d_val for tag in tags if tag.entry.d_tag == "DT_STRSZ")
    previous = b""
    if audits:
        value = audits[-1]
        data = dynamic_bytes(dynamic, value, max(0, old_size - value))
        previous = data[: data.index(b"\0")]
    if auditor in previous.split(b":"):
        return

    combined = previous + b":" + auditor if previous else auditor
    with edit_elf(path) as candidate:
        # patchelf prepends a DT_NEEDED and appends its name to .dynstr, even
        # when a dependency with this name already exists.
        # Supply literal bytes even if an existing auditor name begins with @.
        argument = candidate.parent / "audit-list"
        argument.write_bytes(combined)
        subprocess.run([patchelf, "--add-needed", f"@{argument}", candidate], check=True)
        with candidate.open("r+b") as stream:
            elf = ELFFile(stream)
            dynamic = next(elf.iter_segments(type="PT_DYNAMIC"))
            entry = dynamic.get_tag(0).entry
            if (
                entry.d_tag != "DT_NEEDED"
                or entry.d_val < old_size
                or dynamic_bytes(dynamic, entry.d_val, len(combined) + 1) != combined + b"\0"
            ):
                raise ValueError(f"{path}: patchelf did not prepend the requested dynamic entry")
            entry.d_tag = "DT_AUDIT"
            replacement = elf.structs.Elf_Dyn.build(entry)
            if audits:
                # Drop the temporary first slot and replace the effective old
                # audit entry. Preserve every other byte through DT_NULL.
                last = max(i for i, tag in enumerate(dynamic.iter_tags()) if tag.entry.d_tag == "DT_AUDIT")
                size = len(replacement)
                table = dynamic.data()
                replacement = table[size : last * size] + replacement + table[(last + 1) * size :]
            stream.seek(dynamic["p_offset"])
            stream.write(replacement)


def fix_file(path, policies, patchelf, owner):
    if not stat.S_ISREG(path.lstat().st_mode):
        return
    with path.open("rb") as f:
        if f.read(4) != b"\x7fELF":
            return
        elf = ELFFile(f)
        choices = policies.get(abi(elf))
        if not choices or elf["e_type"] not in ("ET_EXEC", "ET_DYN"):
            return
        if elf["e_ident"]["EI_OSABI"] not in ("ELFOSABI_SYSV", "ELFOSABI_LINUX"):
            return
        own_policy = choices.get(owner)
        policy = own_policy or next(iter(choices.values()))
        segments = list(elf.iter_segments())
        dynamic = next((s for s in segments if s["p_type"] == "PT_DYNAMIC" and s["p_filesz"]), None)
        if dynamic is None:
            return
        tags = list(dynamic.iter_tags())
        needed = {t.needed for t in tags if t.entry.d_tag == "DT_NEEDED"}
        sonames = {t.soname for t in tags if t.entry.d_tag == "DT_SONAME"}
        runtime_names = {"libcuda.so", "libcuda.so.1", "libc.so.6", "libdl.so.2", policy.interpreter}
        if sonames & runtime_names or path.name in runtime_names:
            return
        interp = next((s.get_interp_name() for s in segments if s["p_type"] == "PT_INTERP"), None)
        if interp and os.path.basename(interp) != policy.interpreter:
            return
        pie = any(t.entry.d_tag == "DT_FLAGS_1" and t.entry.d_val & 0x08000000 for t in tags)
        executable = bool(interp and (elf["e_type"] == "ET_EXEC" or pie or not sonames))
        if executable and not elf.num_sections():
            print(f"CUDA compatibility: cannot add DT_AUDIT to sectionless executable {path}", file=sys.stderr)
            executable = False
        # Bind vendor imports to that redistributable's own toolkit wrapper.
        # Propagated inputs add choices for the auditor, not a new import ABI.
        lazy = own_policy and policy.lookup not in needed and imports_glibc_dlopen(elf)
        already_wrapped = any(candidate.lookup in needed for candidate in choices.values())
        shared_runtime = any(name == "libcudart.so" or name.startswith("libcudart.so.") for name in sonames)
        if executable:
            add_audit(path, policy.auditor, patchelf, dynamic, tags)
    if lazy:
        wrap_lookup(path, patchelf, policy.lookup, policy.symbol)
    if executable or lazy or shared_runtime or already_wrapped or "libcuda.so.1" in needed:
        return choices


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", action="append", nargs=5, required=True)
    parser.add_argument("--patchelf", required=True)
    parser.add_argument("--wrap-dlopen", metavar="OWNER_MANIFEST")
    parser.add_argument("outputs", nargs="+", type=Path)
    args = parser.parse_args()
    policies = {}
    for fields in sorted(args.policy):
        policy = Policy(*fields)
        with open(policy.auditor, "rb") as auditor:
            policies.setdefault(abi(ELFFile(auditor)), {})[policy.manifest] = policy
    for output in args.outputs:
        if output.is_symlink():
            continue
        candidates = set()
        for directory, _, filenames in os.walk(output):
            for name in filenames:
                path = Path(directory) / name
                try:
                    found = fix_file(path, policies, args.patchelf, args.wrap_dlopen)
                except ELFError as error:
                    print(f"CUDA compatibility: skipping {path}: {error}", file=sys.stderr)
                    continue
                if found:
                    candidates.update(found)
        if candidates:
            write_candidates(output, candidates)


if __name__ == "__main__":
    main()
