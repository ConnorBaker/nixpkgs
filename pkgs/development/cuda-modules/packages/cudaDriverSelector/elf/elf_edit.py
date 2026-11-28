from contextlib import contextmanager
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


@contextmanager
def edit_elf(path):
    """Replace this directory entry atomically, preserving any other hard links."""
    with tempfile.TemporaryDirectory(dir=path.parent) as tmp:
        target = Path(tmp) / "elf"
        shutil.copy2(path, target)
        mode = stat.S_IMODE(target.stat().st_mode)
        target.chmod(mode | stat.S_IWUSR)
        yield target
        target.chmod(mode)
        target.replace(path)


def imports_glibc_dlopen(elf):
    # patchelf renames every symbol with this name. Only rewrite an unambiguous
    # glibc import, never a definition or an unrelated ABI.
    symbols = elf.get_section_by_name(".dynsym")
    versions = elf.get_section_by_name(".gnu.version")
    needs = elf.get_section_by_name(".gnu.version_r")
    if not (symbols and versions and needs):
        return False
    glibc = {
        aux["vna_other"]
        for lib, auxiliaries in needs.iter_versions()
        if lib.name in ("libdl.so.2", "libc.so.6")
        for aux in auxiliaries
        if aux.name.startswith("GLIBC_")
    }
    found = False
    for i, symbol in enumerate(symbols.iter_symbols()):
        if symbol.name == "dlopen":
            if symbol["st_shndx"] != "SHN_UNDEF" or versions.get_symbol(i)["ndx"] not in glibc:
                return False
            found = True
    return found


def wrap_lookup(path, patchelf, lookup, symbol):
    with edit_elf(path) as target:
        mapping = target.parent / "rename"
        mapping.write_text(f"dlopen {symbol}\n")
        # patchelf clears versions before renaming. The private symbol is
        # unversioned; leaving GLIBC_* on it breaks downstream static linking.
        subprocess.run(
            [patchelf, "--clear-symbol-version", "dlopen", "--rename-dynamic-symbols", mapping, "--add-needed", lookup, target],
            check=True,
        )
