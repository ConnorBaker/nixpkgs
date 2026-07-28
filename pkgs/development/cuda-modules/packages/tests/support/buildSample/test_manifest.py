#!/usr/bin/env python3
"""Tests for `manifest.py`, run in CI by `cudaPackages.tests.sample-manifest-tool`.

`manifest.py` establishes one thing: the set of sample projects in a checkout. It reads no program
names, so there is nothing here about CMake semantics. That is a deliberate reduction, and the
reason for it is worth stating where the tests for the removed code used to be.

Most of this file used to be tests for a static parse of CMake -- variable expansion, `if()`
elimination, project-defined wrapper commands -- written because separate defects in that parse kept
reaching review and nothing else could catch them. `manifest.py`'s own header explains why the parse
was removed rather than repaired; the part that matters here is that the lesson those tests encode
is not "parse more carefully", but that the question has no answer in the sources at all. So program
lists are now asked of CMake, in the environment that builds them, by `buildSample` -- against the
binaries produced, or for a project which does not compile, against CMake's file API through
`passthru.certifyPrograms`. Those checks are build failures, not unit tests, and they live there.

What is left here is the part that is genuinely a property of the tree:

*   `Comments` -- `strip_comments`, which exists so a commented-out `add_subdirectory` does not
    misfile a project as an aggregate entry point.
*   `Scan` -- the project enumeration, which is exact and is what makes an upstream addition,
    removal or rename impossible to miss.
*   `Generate` -- the manifest it writes, and the refusal to emit a project with no program list
    without failing.
*   `CheckRejectsTamperedManifests` -- `check` is the only thing standing between a hand-edited
    manifest and a green CI run, so each way of lying to it gets a test proving it says no,
    finishing with an untampered control.

Everything which needs files on disk builds a synthetic checkout in a temporary directory rather
than using the real CUDALibrarySamples: these tests are about the manifest machinery, not about
upstream, and tying them to a fetched source would make them unrunnable wherever that source is
unavailable and would change their meaning every time upstream moves. Whether the checked-in
manifests still describe upstream is a different question, asked by `cudaPackages.tests.sample-manifests`.
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
        # Beside the subtrees rather than inside one: `scan` looks only for CMakeLists.txt, but a
        # manifest which lived in the tree it describes would be a trap for the next reader.
        path = root / "samples.json"
        path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
        return path

    def run_check(
        self, data: dict[str, object], root: Path, subtrees: list[str] | None = None
    ) -> tuple[int, str]:
        out, err = StringIO(), StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = manifest.check(
                root,
                self.write_manifest(root, data),
                SUBTREES if subtrees is None else subtrees,
            )
        return code, out.getvalue() + err.getvalue()

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

    def test_generate_without_a_previous_manifest_fails(self) -> None:
        """Nothing derives a program list, so a first run has none to offer and must say so."""
        root = self.make_checkout(CHECKOUT)
        code, produced, errors = self.run_generate(root)
        self.assertEqual(code, 1)
        self.assertEqual(produced["samples"]["Alpha/one"], [])
        self.assertIn("Alpha/one", errors)
        self.assertIn("certifyPrograms", errors)

    def test_a_new_upstream_project_comes_back_empty_and_fails(self) -> None:
        """The manifest is complete for what it knew about; the new project is what needs a human."""
        root = self.make_checkout(
            CHECKOUT | {"Alpha/three/CMakeLists.txt": "add_executable(three main.cu)\n"}
        )
        code, produced, errors = self.run_generate(root, self.write_manifest(root, MANIFEST))
        self.assertEqual(code, 1)
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


class CheckRejectsTamperedManifests(CheckoutTestCase):
    """Every tamper must make `check` exit non-zero, for the reason it was tampered with.

    Asserting the exit status alone is not enough: a check which failed for some unrelated reason
    would let the tamper it was meant to catch through, so each test also names the complaint it
    expects to see.
    """

    def setUp(self) -> None:
        self.root = self.make_checkout(CHECKOUT)

    def tampered(self, mutate) -> tuple[int, str]:
        data = copy.deepcopy(MANIFEST)
        mutate(data)
        return self.run_check(data, self.root)

    def test_a_phantom_project_is_rejected(self) -> None:
        code, output = self.tampered(
            lambda data: data["samples"].update({"Alpha/nowhere": ["x"]})
        )
        self.assertEqual(code, 1)
        self.assertIn("no longer exists", output)

    def test_a_deleted_project_is_rejected(self) -> None:
        code, output = self.tampered(lambda data: data["samples"].pop("Alpha/two"))
        self.assertEqual(code, 1)
        self.assertIn("missing from manifest", output)

    def test_a_moved_project_is_rejected(self) -> None:
        def move(data: dict) -> None:
            data["samples"]["Alpha/elsewhere"] = data["samples"].pop("Alpha/two")

        code, output = self.tampered(move)
        self.assertEqual(code, 1)
        self.assertIn("missing from manifest", output)
        self.assertIn("no longer exists", output)

    def test_an_empty_program_list_is_rejected(self) -> None:
        """What `generate` leaves for an uncertified project; it must not reach a build.

        A project declaring no executables builds nothing, installs nothing and succeeds, which is
        the one shape in which the sample machinery goes green having tested nothing at all.
        """
        code, output = self.tampered(
            lambda data: data["samples"].update({"Alpha/two": []})
        )
        self.assertEqual(code, 1)
        self.assertIn("declares no programs", output)

    def test_a_narrowed_subtree_list_in_the_manifest_is_rejected(self) -> None:
        code, output = self.tampered(lambda data: data.update({"subtrees": ["Alpha"]}))
        self.assertEqual(code, 1)
        self.assertIn("subtrees", output)

    def test_a_widened_subtree_list_in_the_manifest_is_rejected(self) -> None:
        code, output = self.tampered(
            lambda data: data.update({"subtrees": ["Alpha", "Beta", "Gamma"]})
        )
        self.assertEqual(code, 1)
        self.assertIn("subtrees", output)

    def test_a_narrowed_subtree_argument_is_rejected(self) -> None:
        """The caller cannot quietly check less than the manifest claims to cover either."""
        code, output = self.run_check(
            copy.deepcopy(MANIFEST), self.root, subtrees=["Alpha"]
        )
        self.assertEqual(code, 1)
        self.assertIn("subtrees", output)

    def test_a_subtree_with_no_projects_is_rejected(self) -> None:
        """A check which enumerates nothing agrees with any manifest at all."""
        root = self.make_checkout({"Alpha/notes.txt": "no CMakeLists here\n"})
        out, err = StringIO(), StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = manifest.check(
                root,
                self.write_manifest(root, {"samples": {}, "subtrees": ["Alpha"]}),
                ["Alpha"],
            )
        self.assertEqual(code, 1)
        self.assertIn("no projects found", out.getvalue() + err.getvalue())

    def test_the_untampered_manifest_passes(self) -> None:
        """The control. Without it every test above could pass because `check` always fails."""
        code, output = self.run_check(copy.deepcopy(MANIFEST), self.root)
        self.assertEqual(code, 0, output)

    def test_the_summary_does_not_claim_a_program_name_was_checked(self) -> None:
        """A green log from this file must not read as though the program lists were verified.

        They were not, and cannot be here. Stated in the output rather than left to be inferred
        from what is absent, because the shape this replaces -- a parser agreeing with itself --
        printed a verified count that meant nothing.
        """
        _, output = self.run_check(copy.deepcopy(MANIFEST), self.root)
        self.assertIn("no program name was checked here", output)
        self.assertIn("buildSample", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
