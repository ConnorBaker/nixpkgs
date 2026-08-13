# Runs the unit tests for `buildSample/manifest.py`.
#
# That file establishes the set of sample projects in a CUDALibrarySamples checkout: a directory
# holding a CMakeLists.txt which does not call `add_subdirectory`. It reads no program names, because
# which executables a project builds is a property of its sources and the component's `buildInputs`
# together rather than of the checkout; `manifest.py`'s header works the example. That question is
# asked of CMake by `buildSample` instead.
#
# What is worth testing here is the enumeration, the manifest `generate` writes, and every way
# of lying to `check`. That is a scan of a temporary directory and some JSON, so it links against
# nothing, fetches nothing and needs no GPU or CUDA component.
{
  cudaMajorMinorVersion,
  cudaNamePrefix,
  lib,
  python3,
  runCommand,
}:
runCommand "${cudaNamePrefix}-sample-manifest-tool-tests"
  {
    __structuredAttrs = true;
    strictDeps = true;

    # Carried so `lib.getName` reads it rather than parsing the name; see the note beside
    # `mkTester`'s `pname`. The code under test is Nixpkgs' own and has no version of its own, so
    # this takes the package set's -- which is what the name prefix already says it belongs to, and
    # is why there is one of these per set rather than one in total.
    pname = "${cudaNamePrefix}-sample-manifest-tool-tests";
    version = cudaMajorMinorVersion;

    nativeBuildInputs = [ python3 ];

    meta = {
      description = "Unit tests for the CUDA sample manifest tool";
      # Not the CUDA EULA and not the sample repository's license: the code under test and the tests
      # themselves are Nixpkgs' own, and nothing else is present in this build.
      license = lib.licenses.mit;
      # `platforms` is deliberately unset so it is populated for us. There is no component here to
      # take it from and nothing platform-specific to run -- this links against nothing, fetches
      # nothing and needs no GPU -- so narrowing it by hand would only mean the tool goes untested
      # wherever the rest of the set is unavailable.
      teams = [ lib.teams.cuda ];
    };
  }
  ''
    set -euo pipefail

    mkdir -p suite
    cp ${./support/buildSample/manifest.py} suite/manifest.py
    cp ${./support/buildSample/test_manifest.py} suite/test_manifest.py

    # A suite which runs no tests at all exits 0, so the count is checked too -- but by the suite
    # itself, against its own `MINIMUM_TESTS`, because there `testsRun` is a number. This used to
    # recover it by matching "Ran N tests" in the log with `sed`, which is unittest's presentation
    # rather than its interface: a reworded summary would have stopped matching, and the floor would
    # have gone unenforced without anything here failing to say so.
    python3 suite/test_manifest.py --verbose 2>&1 | tee "$out"
  ''
