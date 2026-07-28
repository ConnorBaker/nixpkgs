# Runs the unit tests for `buildSample/manifest.py`.
#
# That file establishes the set of sample projects in a CUDALibrarySamples checkout: a directory
# holding a CMakeLists.txt which does not call `add_subdirectory`. It reads no program names, because
# which executables a project builds is a property of its sources and the component's `buildInputs`
# together rather than of the checkout; `manifest.py`'s header works the example. That question is
# asked of CMake by `buildSample` instead.
#
# Most of what this used to run were tests for a static parse of CMake, which `manifest.py`'s own
# header explains the removal of. The short version is that they existed because nothing else could
# catch a defect in that parse, and what replaced it is not a better parse but a different oracle --
# whose checks are build failures rather than unit tests, and live with the build.
#
# What is still worth testing here is the enumeration, the manifest `generate` writes, and every way
# of lying to `check`. That is a scan of a temporary directory and some JSON, so it links against
# nothing, fetches nothing and needs no GPU or CUDA component.
{
  cudaNamePrefix,
  lib,
  python3,
  runCommand,
}:
let
  # `unittest` exits 0 after running no tests at all, so a copy which quietly stopped delivering the
  # test module -- or a rename which left the file unreferenced -- would go green while checking
  # nothing. A floor set below the suite's actual size rather than equal to it: requiring the exact
  # number would turn every added test into a build failure here, while a floor this far under only
  # ever fires on a suite which has stopped running.
  minimumTests = 20;
in
runCommand "${cudaNamePrefix}-sample-manifest-tool-tests"
  {
    __structuredAttrs = true;
    strictDeps = true;

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

    python3 suite/test_manifest.py --verbose 2>&1 | tee test.log

    ran="$(sed -n 's/^Ran \([0-9][0-9]*\) tests\? in .*/\1/p' test.log)"
    if [[ -z "''${ran}" ]] || ((ran < ${toString minimumTests})); then
      nixErrorLog "the suite reported ''${ran:-no} tests, fewer than the ${toString minimumTests} expected"
      nixErrorLog "a suite which runs nothing passes no matter what the tool does"
      exit 1
    fi

    cp test.log "$out"
  ''
