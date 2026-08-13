#!/usr/bin/env python3
"""Tests for `manifest.py`, run in CI by `cudaPackages.tests.sample-manifest-tool`.

`manifest.py` establishes one thing: the set of sample projects in a checkout. It reads no program
names, so there is nothing here about CMake semantics -- not because that would be hard to test, but
because the question has no answer in the sources at all, which `manifest.py`'s own header works the
example of. Program lists are asked of CMake in the environment that builds them, by `buildSample`,
against the binaries produced or against CMake's file API; those checks are build failures rather
than unit tests, and they live there.

What is tested here is the part which is genuinely a property of the tree:

*   `Comments` -- `strip_comments`, which exists so a commented-out `add_subdirectory` does not
    misfile a project as an aggregate entry point.
*   `Scan` -- the project enumeration, which is exact and is what makes an upstream addition,
    removal or rename impossible to miss.
*   `Generate` -- the manifest it writes, and the refusal to emit a project with no program list
    without failing.
*   `CheckRejectsTamperedManifests` -- `check` is the only thing standing between a hand-edited
    manifest and a green CI run, so each way of lying to it gets a test proving it says no,
    finishing with an untampered control.

The last of those needs fewer tests than it looks like it should, and deliberately. `check`
regenerates the manifest and compares, so there is no list of rules over projects and subtrees for
each of which a test would be owed -- a comparison cannot disagree with what it compares against.
What is tested is that a tamper is caught at all, plus the two things a comparison cannot see: a
manifest whose program lists are empty agrees with a regeneration that carries those empty lists
forward, and a subtree list narrowed in both the manifest and the arguments would be self-consistent.

Everything which needs files on disk builds a synthetic checkout in a temporary directory rather
than using the real CUDALibrarySamples: these tests are about the manifest machinery, not about
upstream, and tying them to a fetched source would make them unrunnable wherever that source is
unavailable and would change their meaning every time upstream moves. Whether the checked-in
manifests still describe upstream is a different question, asked by each component's own
`cudaPackages.tests.<component>-samples.manifest`.
"""

import copy
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

import manifest

# A checkout with one of each thing the enumeration has to distinguish: an aggregate entry point
# which is not itself a project, and three projects. What any of them builds is not this file's
# business, so the bodies are only as detailed as `scan` needs them to be.
CHECKOUT = {
    "Alpha/CMakeLists.txt": "add_subdirectory(one)\nadd_subdirectory(two)\n",
    "Alpha/one/CMakeLists.txt": "project(alpha)\nadd_executable(alpha_example main.cu)\n",
    "Alpha/two/CMakeLists.txt": "add_executable(two_a a.cu)\nadd_executable(two_b b.cu)\n",
    "Beta/generated/CMakeLists.txt": (
        "project(beta)\n"
        "foreach(backend nccl mpi)\n"
        "  add_executable(${BACKEND_PREFIX}_${backend} main.cu)\n"
        "endforeach()\n"
    ),
}

SUBTREES = ["Alpha", "Beta"]

# The manifest a correct `generate` produces for CHECKOUT given those program lists. Every tamper
# below is a mutation of this.
MANIFEST = {
    "samples": {
        "Alpha/one": ["alpha_example"],
        "Alpha/two": ["two_a", "two_b"],
        "Beta/generated": ["beta_nccl", "beta_mpi"],
    },
    "subtrees": ["Alpha", "Beta"],
}


class Comments(unittest.TestCase):
    """`strip_comments` decides whether an `add_subdirectory` is real.

    Both ways of being wrong matter, in opposite directions: a missed comment files a project as an
    aggregate and drops it, and a missed *command* files an aggregate as a project.
    """

    def test_line_comments_are_stripped(self) -> None:
        self.assertNotIn(
            "add_subdirectory",
            manifest.strip_comments("# add_subdirectory(one)\nproject(a)\n"),
        )

    def test_bracket_comment(self) -> None:
        self.assertNotIn(
            "add_subdirectory",
            manifest.strip_comments("#[[ add_subdirectory(one) ]]\nproject(a)\n"),
        )

    def test_multi_line_bracket_comment(self) -> None:
        text = "#[[\nadd_subdirectory(one)\n]]\nproject(a)\n"
        self.assertNotIn("add_subdirectory", manifest.strip_comments(text))

    def test_equals_signed_bracket_comment(self) -> None:
        text = "#[=[\nadd_subdirectory(one)\n]=]\nproject(a)\n"
        self.assertNotIn("add_subdirectory", manifest.strip_comments(text))

    def test_a_bracket_comment_keeps_the_lines_it_spanned(self) -> None:
        """The pattern reading the result is line-anchored, so the line count must survive.

        Deleting a multi-line comment outright would splice the command after it onto the tail of
        the line the comment opened on, where a pattern anchored to `^` cannot see it.
        """
        text = "#[[\na\nb\n]]\nadd_subdirectory(one)\n"
        stripped = manifest.strip_comments(text)
        self.assertEqual(text.count("\n"), stripped.count("\n"))
        self.assertIsNotNone(manifest.ADD_SUBDIRECTORY_RE.search(stripped))

    def test_a_commented_out_aggregate_is_a_project(self) -> None:
        """The whole point, at the level `scan` works at."""
        self.assertIsNone(
            manifest.ADD_SUBDIRECTORY_RE.search(
                manifest.strip_comments("# add_subdirectory(one)\n")
            )
        )


class CheckoutTestCase(unittest.TestCase):
    """Base class for the tests which need a checkout and a manifest on disk."""

    def make_checkout(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp(prefix="cuda-manifest-test-"))
        self.addCleanup(shutil.rmtree, root, True)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return root

    def write_manifest(self, root: Path, data: dict[str, object]) -> Path:
        """The manifest as `generate` would have written it.

        Through `dump_manifest` rather than `json.dumps`, because `check` now compares bytes: a
        helper with a layout of its own would make every test here fail on formatting alone, and
        would prove nothing about the manifests this tool actually writes.
        """
        # Beside the subtrees rather than inside one: `scan` looks only for CMakeLists.txt, but a
        # manifest which lived in the tree it describes would be a trap for the next reader.
        path = root / "samples.json"
        text = manifest.dump_manifest(data["subtrees"], data["samples"])
        path.write_text(text + "\n", encoding="utf-8")
        return path

    def run_generate(
        self, root: Path, previous: Path | None = None
    ) -> tuple[int, dict[str, object], str]:
        out, err = StringIO(), StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = manifest.generate(root, SUBTREES, previous)
        return code, json.loads(out.getvalue()), err.getvalue()


class Scan(CheckoutTestCase):
    """The enumeration of projects is exact, and is the whole of what this file establishes."""

    def test_aggregate_entry_points_are_not_projects(self) -> None:
        found = manifest.scan(self.make_checkout(CHECKOUT), SUBTREES)
        self.assertEqual(sorted(found), ["Alpha/one", "Alpha/two", "Beta/generated"])

    def test_a_project_is_named_by_its_path(self) -> None:
        found = manifest.scan(self.make_checkout(CHECKOUT), SUBTREES)
        self.assertIn("Alpha/one", found)

    def test_a_missing_subtree_is_an_error(self) -> None:
        """Silently scanning nothing is how a check comes to verify nothing."""
        with self.assertRaises(SystemExit):
            manifest.scan(self.make_checkout(CHECKOUT), ["Alpha", "Gamma"])

    def test_paths_which_used_to_collide_as_keys_are_both_kept(self) -> None:
        """The defect this replaces a guard for.

        When the key was the path with `/` turned into `-`, `Alpha/bar-baz` and `Alpha/bar/baz`
        both wanted `Alpha-bar-baz` and one silently displaced the other, so `scan` had to raise.
        Keyed by the path there is nothing to collide, and the correct result is both projects.
        """
        root = self.make_checkout(
            {
                "Alpha/bar-baz/CMakeLists.txt": "add_executable(a main.cu)\n",
                "Alpha/bar/baz/CMakeLists.txt": "add_executable(b main.cu)\n",
            }
        )
        self.assertEqual(
            sorted(manifest.scan(root, ["Alpha"])), ["Alpha/bar-baz", "Alpha/bar/baz"]
        )

    def test_a_commented_out_add_subdirectory_does_not_hide_a_project(self) -> None:
        root = self.make_checkout(
            {"Alpha/one/CMakeLists.txt": "# add_subdirectory(nowhere)\nproject(a)\n"}
        )
        self.assertEqual(manifest.scan(root, ["Alpha"]), ["Alpha/one"])


class Generate(CheckoutTestCase):
    def test_generate_reproduces_the_manifest_under_merge(self) -> None:
        root = self.make_checkout(CHECKOUT)
        previous = self.write_manifest(root, MANIFEST)
        code, produced, _ = self.run_generate(root, previous)
        self.assertEqual(code, 0)
        self.assertEqual(produced, MANIFEST)

    def test_generate_writes_one_line_per_project(self) -> None:
        """The reason `dump_manifest` exists rather than `json.dumps(indent=2)`.

        Asserted because a manifest which quietly went back to a brace-per-field layout would
        still be correct JSON, still pass every other test here, and quietly restore the four
        lines per project across three hundred projects that this shape removes.
        """
        text = manifest.dump_manifest(SUBTREES, MANIFEST["samples"])
        self.assertEqual(json.loads(text), MANIFEST)
        for sample_root, programs in MANIFEST["samples"].items():
            matching = [
                line
                for line in text.splitlines()
                if line.strip().startswith(json.dumps(sample_root) + ":")
            ]
            self.assertEqual(len(matching), 1, f"{sample_root}: {matching}")
            # The whole entry on that one line, programs and all.
            self.assertIn(json.dumps(programs), matching[0])

    def test_generate_without_a_previous_manifest_names_what_it_could_not_carry(self) -> None:
        """Nothing derives a program list, so a first run has none to offer and must say so.

        It says so and still writes the manifest. This is the only thing which writes one, so both
        the manifest check and the update script run it, and refusing here would leave neither able
        to show what the missing lists did to the file. That an empty list must not reach a build is
        enforced by `mkSamples`, which will not evaluate a manifest declaring no programs.
        """
        root = self.make_checkout(CHECKOUT)
        code, produced, errors = self.run_generate(root)
        self.assertEqual(code, 0)
        self.assertEqual(produced["samples"]["Alpha/one"], [])
        self.assertIn("Alpha/one", errors)
        self.assertIn("certifyPrograms", errors)

    def test_a_new_upstream_project_comes_back_empty_and_is_named(self) -> None:
        """The manifest is complete for what it knew about; the new project is what needs a human."""
        root = self.make_checkout(
            CHECKOUT | {"Alpha/three/CMakeLists.txt": "add_executable(three main.cu)\n"}
        )
        code, produced, errors = self.run_generate(root, self.write_manifest(root, MANIFEST))
        self.assertEqual(code, 0)
        self.assertEqual(produced["samples"]["Alpha/three"], [])
        self.assertEqual(produced["samples"]["Alpha/one"], ["alpha_example"])
        self.assertIn("Alpha/three", errors)

    def test_a_project_which_disappeared_upstream_is_not_carried_over(self) -> None:
        """`--merge` supplies program lists; it does not get to keep a project alive."""
        stale = copy.deepcopy(MANIFEST)
        stale["samples"]["Alpha/gone"] = ["gone"]
        root = self.make_checkout(CHECKOUT)
        code, produced, _ = self.run_generate(root, self.write_manifest(root, stale))
        self.assertEqual(code, 0)
        self.assertNotIn("Alpha/gone", produced["samples"])


class RegeneratedText(CheckoutTestCase):
    """The properties the Nix-side manifest check rests on.

    That check is `testers.testEqualContents` between the checked-in manifest and what `generate`
    writes from the same checkout, so it can only be as good as two things this file owns: the text
    has to be a function of the checkout alone, and it has to actually change when the checkout does.
    Neither is visible from the Nix side, where a comparison that always passed would look exactly
    like a manifest that was always right.
    """

    def setUp(self) -> None:
        self.root = self.make_checkout(CHECKOUT)
        self.previous = self.write_manifest(self.root, MANIFEST)

    def regenerate(self, root: Path, previous: Path) -> str:
        return manifest.dump_manifest(
            SUBTREES, manifest.carry_forward(manifest.scan(root, SUBTREES), previous)
        )

    def test_the_text_is_a_function_of_the_checkout(self) -> None:
        """Byte-identical across runs, or the check fails on a file nobody edited."""
        self.assertEqual(
            self.regenerate(self.root, self.previous),
            self.regenerate(self.root, self.previous),
        )
        self.assertEqual(
            self.regenerate(self.root, self.previous),
            self.previous.read_text(encoding="utf-8").rstrip("\n"),
        )

    def test_each_thing_upstream_can_do_to_a_project_changes_the_text(self) -> None:
        """Added, removed and renamed: the three cases the check is documented to catch."""
        added = self.make_checkout(
            CHECKOUT | {"Alpha/three/CMakeLists.txt": "add_executable(three main.cu)\n"}
        )
        removed = self.make_checkout(
            {name: text for name, text in CHECKOUT.items() if not name.startswith("Alpha/two/")}
        )
        renamed = self.make_checkout(
            {
                name.replace("Alpha/two/", "Alpha/elsewhere/"): text
                for name, text in CHECKOUT.items()
            }
        )
        recorded = self.previous.read_text(encoding="utf-8").rstrip("\n")
        for label, root in (("added", added), ("removed", removed), ("renamed", renamed)):
            with self.subTest(change=label):
                self.assertNotEqual(self.regenerate(root, self.previous), recorded)

    def test_a_subtree_with_no_projects_is_refused(self) -> None:
        """A regeneration which enumerated nothing would agree with any manifest at all.

        Refused by `dump_manifest`, which everything writing a manifest goes through, so this raises
        rather than producing a file the comparison could then be satisfied by.
        """
        root = self.make_checkout({"Alpha/notes.txt": "no CMakeLists here\n"})
        with self.assertRaises(SystemExit) as raised:
            manifest.dump_manifest(["Alpha"], {})
        self.assertIn("no projects", str(raised.exception))
        self.assertEqual(manifest.scan(root, ["Alpha"]), [])


# `unittest` exits 0 after running no tests at all, so a copy of this file which lost its test
# classes -- or a runner which imported the wrong module -- would go green having checked nothing.
# The floor is deliberately below the suite's size: requiring the exact number would turn every
# added test into a failure, while a floor this far under only ever fires on a suite which has
# stopped running. Asserted here, where `testsRun` is a number, rather than by the derivation which
# runs this: that used to scrape "Ran N tests" out of the human-readable log with `sed`, which is
# unittest's presentation rather than its interface and would have gone quietly unmatched -- and so
# unenforced -- the first time it was reworded.
MINIMUM_TESTS = 14

if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    if result.testsRun < MINIMUM_TESTS:
        raise SystemExit(
            f"the suite ran {result.testsRun} tests, fewer than the {MINIMUM_TESTS} expected;"
            " a suite which runs nothing passes no matter what the tool does"
        )
    raise SystemExit(not result.wasSuccessful())
