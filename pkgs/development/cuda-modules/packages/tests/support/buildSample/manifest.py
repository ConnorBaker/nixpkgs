#!/usr/bin/env python3
"""Generate or check a sample manifest for subtrees of NVIDIA's CUDALibrarySamples.

The repository has no root build and no machine-readable index, so the set of sample projects must
be recovered from the tree itself. The result is checked into the tree because discovering it at
evaluation time would require import-from-derivation.

    manifest.py generate [--merge <old>] <checkout> <subtree>...  write a manifest to stdout
    manifest.py check <checkout> <manifest> <subtree>...          compare manifest against checkout

A manifest maps each project's path within the checkout to the executables it builds:

    {
      "samples": {"cuBLAS/Level-1/dot": ["cublas_dot_example", "cublas_dotc_example"]},
      "subtrees": ["cuBLAS"]
    }

The path is the key because it is what everything else keys on: `sampleArgs` and `testArgs` in a
component's package.nix, the `sampleRoot` handed to `buildSample`, and the upstream URL in each
sample's `meta.homepage`. An earlier schema stored a dash-joined mangling of it as the key and the
path again as a field, which cost a line per project, made two spellings of one fact drift-prone,
and let two distinct projects collide onto one key -- `a/b-c` and `a-b/c` both mangle to `a-b-c` --
which needed a uniqueness check that a path-keyed manifest does not.

The two halves of a manifest carry very different weight, and this file speaks to one of them:

*   The set of projects is exact, and is what this file establishes. A project is a directory
    containing a CMakeLists.txt which does not call `add_subdirectory` -- the ones which do are
    aggregate entry points whose leaves we build instead -- and that is an `rglob` and one
    predicate, with no guessing involved. `check` enforces it strictly in both directions, which is
    the guarantee that an upstream addition, removal or rename cannot go unnoticed.

*   The set of executables a project builds is NOT established here, and nothing in this file reads
    a program name out of a CMakeLists.txt. That question has no answer in the sources alone.
    `nvCOMP/examples` guards `gzip_gpu_decompression` with `if (ZLIB_FOUND)` and
    `zstd_cpu_compression` with `if (ZSTD_INCLUDE_DIR AND ZSTD_LIBRARY)`: structurally identical
    conditions which decide opposite ways depending only on what the derivation building them puts
    in `buildInputs`. Whichever answer a reader of the text gives, it is wrong for some package set.

This file used to contain a static parse of CMake -- variable expansion, `if()` elimination, and
resolution of project-defined wrapper commands -- and `check` compared each manifest entry against
it. That was removed rather than repaired. It agreed with CMake on 205 of the 207 projects which
could be configured, and the 2 it got wrong were the two nobody could have caught: `nvCOMP`'s
projects do not compile against the nvCOMP this tree ships, so `buildSample`'s
declared-against-produced check had never run on them. It declared one program for
`nvCOMP/benchmarks` which is not built and missed the nine which are, and for `nvCOMP/examples` it
invented three names and missed three others. The parse was right exactly where something else was
already checking, and wrong exactly where nothing was.

So program lists are asked of CMake, by `buildSample`, in the environment that actually builds them:

*   For a project which compiles, `buildSample`'s `installPhase` compares the declared list against
    the executables in the build tree, exactly and in both directions.
*   For a project which does not -- where the first check can never run -- `passthru.certifyPrograms`
    configures the project and compares the declared list against CMake's file API. It compiles
    nothing and needs no GPU, but it does need the component, so it lives with the build rather than
    here.

`generate` therefore carries program lists forward rather than deriving them, and emits an empty
list for a project it has not seen before, failing so that someone runs the certification and pastes
in what CMake reports. `check` verifies the project set, the subtree coverage, and that no project
was left with an empty list; it deliberately makes no claim about program names, and says so.

`check` takes the subtrees it must cover as arguments rather than reading them from the manifest,
because a manifest which declares the coverage it is checked against can always claim less.

Requirements (`minCudaVersion`, `minCudaCapability`) are NOT generated. Upstream does not state them
reliably: most READMEs say "All GPUs supported by CUDA Toolkit", the enumerated ones are stale, and
cuBLASLt has no READMEs at all. They are curated in the component's package.nix and established by
building against the oldest supported package set and running on real hardware.
"""

import json
import re
import sys
from pathlib import Path

# CMake commands are case-insensitive, and the samples are inconsistent about it: cuBLAS writes
# `add_executable(`, NPP writes `ADD_EXECUTABLE(`. Matching only one case silently skipped whole
# subtrees, so every command pattern here is case-insensitive.
FLAGS = re.MULTILINE | re.IGNORECASE


# cmake-language(7) allows whitespace between a command's name and its opening paren, and the
# samples use it: nvCOMP writes `add_subdirectory (examples)`. A command this file cannot see is a
# project it silently misfiles, so the pattern admits the space.
def command(name: str) -> str:
    return rf"^\s*{name}\s*\("


LINE_COMMENT_RE = re.compile(r"#.*$", re.MULTILINE)
# `#[[ ... ]]`, `#[=[ ... ]=]`: a comment which may span lines. The bracket length must match, hence
# the backreference.
BRACKET_COMMENT_RE = re.compile(r"#\[(=*)\[.*?\]\1\]", re.DOTALL)
ADD_SUBDIRECTORY_RE = re.compile(command("add_subdirectory"), FLAGS)


def strip_comments(text: str) -> str:
    """Remove comments so a commented-out command is not read as a real one.

    Bracket comments are removed before line comments: they open with a `#`, so stripping line
    comments first would take the opening line and leave the body of a multi-line one behind as
    apparently live code. Their newlines are kept, because the pattern this feeds is line-anchored:
    deleting them outright would splice a command onto the tail of the line the comment started on,
    where a pattern anchored to `^` cannot see it.

    One command is read out of the result, `add_subdirectory`, and it decides whether a directory is
    an aggregate entry point or a project. Both ways of being wrong are caught: a missed
    `add_subdirectory` files an aggregate as a project, whose build then fails for want of anything
    to build, and a spurious one drops a real project, which `check` reports as an upstream project
    missing from the manifest.
    """
    unbracketed = BRACKET_COMMENT_RE.sub(
        lambda match: "\n" * match.group().count("\n"), text
    )
    return LINE_COMMENT_RE.sub("", unbracketed)


def scan(checkout: Path, subtrees: list[str]) -> list[str]:
    """Every sample project in the given subtrees, as paths within the checkout.

    The enumeration is exact. Paths cannot collide: a project is a directory, and two directories
    with the same path are the same directory.
    """
    projects: list[str] = []

    for subtree in sorted(subtrees):
        root = checkout / subtree
        if not root.is_dir():
            raise SystemExit(f"subtree {subtree} does not exist in {checkout}")
        for cmakelists in sorted(root.rglob("CMakeLists.txt")):
            text = strip_comments(
                cmakelists.read_text(encoding="utf-8", errors="replace")
            )
            if ADD_SUBDIRECTORY_RE.search(text):
                continue  # an aggregate entry point; we build its leaves instead
            projects.append(cmakelists.parent.relative_to(checkout).as_posix())

    return projects


def dump_manifest(subtrees: list[str], samples: dict[str, list[str]]) -> str:
    """The manifest as text, one line per project.

    Written out rather than handed to `json.dumps(indent=2)` for that shape alone: a regenerated
    manifest then reads as a diff of the projects which changed rather than of the braces around
    every project which did not. The result is parsed back and compared with what was asked for
    before it is returned, so this cannot emit anything but the manifest it was given.
    """
    document = {"samples": samples, "subtrees": sorted(subtrees)}
    body = ",\n".join(
        f"    {json.dumps(root)}: {json.dumps(samples[root])}" for root in sorted(samples)
    )
    text = (
        "{\n"
        '  "samples": {\n'
        f"{body}\n"
        "  },\n"
        f'  "subtrees": {json.dumps(document["subtrees"])}\n'
        "}"
    )
    if json.loads(text) != document:
        raise SystemExit("manifest emission produced something other than the manifest")
    return text


def generate(checkout: Path, subtrees: list[str], previous: Path | None) -> int:
    """Emit a manifest for the projects found, carrying program lists over from an old one.

    Nothing here derives a program list; `--merge` is how an existing one survives a regeneration.
    A project the old manifest does not have -- a new one upstream, or the first run for a component
    -- comes back with an empty list and this returns non-zero, so that a regeneration which needs
    someone to go and certify the new project cannot be mistaken for one which does not.
    """
    found = scan(checkout, subtrees)

    inherited: dict[str, list[str]] = {}
    if previous is not None and previous.is_file():
        old = json.loads(previous.read_text(encoding="utf-8"))
        inherited = old.get("samples", {})

    samples = {sample_root: inherited.get(sample_root, []) for sample_root in found}
    uncertified = [sample_root for sample_root, programs in samples.items() if not programs]

    print(dump_manifest(subtrees, samples))

    if uncertified:
        print(
            f"{len(uncertified)} project(s) have no program list. Build each one's"
            " `passthru.certifyPrograms`, which fails naming exactly what CMake builds, and paste"
            " that in:",
            file=sys.stderr,
        )
        for sample_root in uncertified:
            print(f"  {sample_root}", file=sys.stderr)
        return 1
    return 0


def check(checkout: Path, manifest_path: Path, subtrees: list[str]) -> int:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    recorded: dict[str, list[str]] = manifest["samples"]
    found = set(scan(checkout, subtrees))

    problems: list[str] = []

    # The manifest does not get to choose what it is checked against. Its own list is required to
    # agree with the one supplied, so narrowing coverage means editing two files, one of which is
    # not the manifest.
    if sorted(manifest.get("subtrees", [])) != sorted(subtrees):
        problems.append(
            f"manifest records subtrees {sorted(manifest.get('subtrees', []))} but is being"
            f" checked against {sorted(subtrees)}"
        )

    for sample_root in sorted(found - set(recorded)):
        problems.append(f"upstream project missing from manifest: {sample_root}")

    for sample_root in sorted(set(recorded) - found):
        problems.append(f"manifest names a project which no longer exists: {sample_root}")

    # An empty list is what `generate` leaves behind for a project nobody has certified yet. It
    # would otherwise pass everything here and reach `buildSample` as a project expected to build no
    # executables, which installs nothing and succeeds.
    for sample_root in sorted(set(recorded) & found):
        if not recorded[sample_root]:
            problems.append(
                f"{sample_root}: declares no programs; build its `passthru.certifyPrograms` and"
                " record what CMake reports"
            )

    # A manifest covering no projects would satisfy every rule above without testing any of them.
    # The subtrees are named by the caller, so this fires on a component whose subtree exists and is
    # empty of projects, which is a mistake in the subtree list rather than a true description.
    if not found:
        problems.append(
            f"no projects found under {sorted(subtrees)}; this check would pass no matter what the"
            " manifest said"
        )

    if problems:
        print(f"manifest {manifest_path} does not match {checkout}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    programs = sum(len(declared) for declared in recorded.values())
    print(f"manifest {manifest_path}: {len(recorded)} projects, {programs} programs")
    print(f"  {len(recorded)} of {len(recorded)} projects accounted for in {checkout}")
    # Said outright rather than left to be inferred from what is absent. Everything above is true --
    # the set of projects is exact, and an upstream addition, removal or rename fails here -- but no
    # program name was compared against anything, and a green log from this file must not be read as
    # saying otherwise.
    print(
        "  no program name was checked here: which executables a project builds depends on the"
        " component and the inputs it is built with, so it is checked by buildSample -- against the"
        " binaries produced, or for a project which does not compile, against CMake's file API"
    )
    return 0


def main(argv: list[str]) -> int:
    match argv:
        case ["generate", "--merge", previous, checkout, *subtrees] if subtrees:
            return generate(Path(checkout), list(subtrees), Path(previous))
        case ["generate", checkout, *subtrees] if subtrees:
            return generate(Path(checkout), list(subtrees), None)
        case ["check", checkout, manifest, *subtrees] if subtrees:
            return check(Path(checkout), Path(manifest), list(subtrees))
        case _:
            print(__doc__, file=sys.stderr)
            return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
