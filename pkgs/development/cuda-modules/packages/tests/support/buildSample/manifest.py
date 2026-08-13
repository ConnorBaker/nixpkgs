#!/usr/bin/env python3
"""Generate a sample manifest for subtrees of NVIDIA's CUDALibrarySamples.

The repository has no root build and no machine-readable index, so the set of sample projects must
be recovered from the tree itself. The result is checked into the tree because discovering it at
evaluation time would require import-from-derivation.

    manifest.py generate [--merge <old>] <checkout> <subtree>...  write a manifest to stdout

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
    predicate, with no guessing involved. Comparing what this writes against what is checked in is
    the guarantee that an upstream addition, removal or rename cannot go unnoticed.

*   The set of executables a project builds is NOT established here, and nothing in this file reads
    a program name out of a CMakeLists.txt. That question has no answer in the sources alone.
    `nvCOMP/examples` guards `gzip_gpu_decompression` with `if (ZLIB_FOUND)` and
    `zstd_cpu_compression` with `if (ZSTD_INCLUDE_DIR AND ZSTD_LIBRARY)`: structurally identical
    conditions which decide opposite ways depending only on what the derivation building them puts
    in `buildInputs`. Whichever answer a reader of the text gives, it is wrong for some package set.

    A static parse is not the answer to that, and its failure mode is worth stating because it is
    not "somewhat inaccurate". Measured against CMake over these subtrees, a parse which expanded
    variables, eliminated `if()` and resolved the projects' own wrapper commands agreed on 205 of
    the 207 projects which could be configured -- and the two it got wrong were the two nobody could
    have caught, because `nvCOMP`'s projects did not compile here and so had never reached the
    check which compares a declared list against the executables produced. It was right exactly
    where something else was already checking, and wrong exactly where nothing was.

So program lists are asked of CMake, by `buildSample`, in the environment that actually builds them:

*   For a project which compiles, `buildSample`'s `installPhase` compares the declared list against
    the executables in the build tree, exactly and in both directions.
*   For a project which does not -- where the first check can never run -- `passthru.certifyPrograms`
    configures the project and compares the declared list against CMake's file API. It compiles
    nothing and needs no GPU, but it does need the component, so it lives with the build rather than
    here.

`generate` therefore carries program lists forward rather than deriving them, and emits an empty
list for a project it has not seen before, naming it on stderr so that someone runs the
certification and pastes in what CMake reports.

There is no `check` subcommand, and deliberately so. Checking a manifest means regenerating it from
the checkout and comparing the two, which is `testers.testEqualContents` over this program's output
-- so the check is a comparison rather than a second set of rules about projects and subtrees, and
there is no second implementation for the first to drift away from. `mkSampleManifestCheck` wires
that up and hangs the regenerated manifest off it, which is also what the component's
`passthru.updateScript` copies into place: the file a maintainer writes and the file the check
compares against are then the same bytes from the same command, rather than two things that agree
until they do not.

The subtrees to cover are arguments here and are declared by the component rather than read out of
the manifest, because a manifest which declares the coverage it is checked against can always claim
less.

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

    This is the single definition of what a manifest looks like, which is what lets `check` be a
    comparison against `generate` rather than a second implementation of it.

    A manifest describing no projects is refused outright, here rather than in either subcommand,
    because neither has a use for one: it would match any checkout at all, so every check made
    against it would pass having verified nothing, and generating one means the subtree list is
    wrong. An *empty program list* is a different matter and is not refused here -- `generate` emits
    exactly that for a project nobody has certified yet, which is how the next person is told what
    to fill in. `check` is where such a manifest is rejected, because that is where one would
    otherwise be used.
    """
    if not samples:
        raise SystemExit(
            "a manifest describing no projects would match any checkout at all, so every check"
            " made against it would pass having verified nothing; the subtrees it was given"
            " contain no project, which is a mistake in the subtree list rather than a true"
            " description"
        )

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


def carry_forward(found: list[str], previous: Path | None) -> dict[str, list[str]]:
    """The `samples` of a manifest for the projects found, with program lists from an old one.

    Nothing here derives a program list, so this is the only way an existing one survives. A project
    the old manifest does not have comes back empty, and a project the old manifest has which the
    checkout does not is dropped: `--merge` supplies program lists, it does not get to keep a
    project alive.

    Shared with `check`, which is what makes that a comparison against `generate` rather than a
    reimplementation of it: both arrive at the manifest this checkout implies by the same route, so
    there is no second answer for the two to disagree about.
    """
    inherited: dict[str, list[str]] = {}
    if previous is not None and previous.is_file():
        inherited = json.loads(previous.read_text(encoding="utf-8")).get("samples", {})
    return {sample_root: inherited.get(sample_root, []) for sample_root in found}


def generate(checkout: Path, subtrees: list[str], previous: Path | None) -> int:
    """Emit a manifest for the projects found, carrying program lists over from an old one.

    Nothing here derives a program list; `--merge` is how an existing one survives a regeneration.
    A project the old manifest does not have -- a new one upstream, or the first run for a component
    -- comes back with an empty list, named on stderr so that a regeneration needing someone to go
    and certify a new project says so.

    It is named rather than refused. This is the only thing which writes a manifest, so the manifest
    check and the update script both run it, and exiting non-zero here would mean neither could show
    what a new project did to the file. What must not happen is the empty list going unnoticed, and
    that is enforced where the manifest is read: `mkSamples` refuses to evaluate a manifest which
    declares no programs for a project, in a message naming it. Failing there rather than here also
    covers the manifest nobody regenerated, which this could never have seen.
    """
    samples = carry_forward(scan(checkout, subtrees), previous)
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
    return 0


def main(argv: list[str]) -> int:
    match argv:
        case ["generate", "--merge", previous, checkout, *subtrees] if subtrees:
            return generate(Path(checkout), list(subtrees), Path(previous))
        case ["generate", checkout, *subtrees] if subtrees:
            return generate(Path(checkout), list(subtrees), None)
        case _:
            print(__doc__, file=sys.stderr)
            return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
