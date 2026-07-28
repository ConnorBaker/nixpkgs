# Builds an executable which runs a single sample program. The executable is registered as
# `meta.mainProgram` so it can be run directly, which is what lets `mkTest` derive a sandboxed run
# from it without duplicating the invocation, and what lets a user run the same test outside the
# sandbox under nixGL.
#
# The program is run in a scratch directory rather than wherever the caller happens to stand,
# because running these samples is not simply invoking a binary. Upstream writes them to be run from
# a build directory inside their own source tree: several open input files by a path relative to the
# working directory (`images/`, `../images/`, `NVLogo.jpg`), and several write their results beside
# those inputs. Without a working directory prepared for them they do not fail loudly -- NPP's
# `findContour` reports `NPP Library Version 12.4.1`, three more lines, and exits 0 having loaded
# nothing -- so a test which only checked the exit status was green while the sample did no work.
# `expectedOutputs` is what closes that: a run which produced nothing is a failure here even when
# the program says otherwise.
{
  coreutils,
  cudaNamePrefix,
  lib,
  writeShellApplication,
}:
{
  # The component whose samples are being run, used to name the tester and to inherit metadata.
  component,
  # A short name for this particular test.
  name,
  # The derivation providing the sample executable, built by `buildSample`.
  sample,
  # The command to run, as a list; the first element is an executable from `sample`.
  cmdArgs,
  # Extra derivations to place on PATH.
  runtimeInputs ? [ ],
  # Environment the program needs, exported before it runs. A sample which `dlopen`s a driver
  # library by soname finds nothing in the sandbox -- there is no ld.so cache there -- so the search
  # path has to be given to it.
  runtimeEnv ? null,

  # dataFiles :: { <path under the working tree> = <path to copy there>; }
  # Input data the program opens by a relative path, copied into the scratch tree before the run.
  # Copied rather than symlinked, and made writable, because the samples which read from a directory
  # are the same ones which write their results back into it.
  dataFiles ? { },
  # workSubdir :: String
  # Directory within the scratch tree to run from, relative to the root the `dataFiles` paths are
  # resolved against. Upstream's samples are run from a build directory inside the project, so one
  # reads `images/` and its neighbour reads `../images/`; giving the second `workSubdir = "build"`
  # places the same `dataFiles` entry where each of them looks, without any path here having to
  # climb out of the scratch tree.
  workSubdir ? ".",
  # expectedOutputs :: [ String ]
  # Files, named relative to the scratch tree's root, which must exist and be non-empty when the
  # program is done. Their parent directories are created before the run: these samples write into a
  # directory named on the command line and do not create it themselves.
  expectedOutputs ? [ ],
  # problems :: AttrsOf Problem
  # Reasons this *executable* cannot be run here, as opposed to the sample's own, which are inherited
  # below. A project builds several programs from one compile and they do not fail together:
  # `cuFFT/lto_callback_window_1d` builds three, of which two run and one cannot make its plan. A
  # problem on the sample would take all three down with it, and marking none of them would leave a
  # test which is expected to fail.
  problems ? { },
}:
let
  # The executable this tester runs, which is `cmdArgs` minus whatever it is being given. Named once
  # because it is the tester's subject: it appears in the description, in the check that the sample
  # actually provides it, and in the failure message when nothing was written.
  program = builtins.head cmdArgs;

  paths = lib.attrNames dataFiles ++ expectedOutputs ++ [ workSubdir ];

  # Every path above is resolved against the scratch tree's root and must stay inside it, so that
  # what a test writes cannot land outside the directory cleaned up afterwards. `..` is rejected
  # rather than normalised: `workSubdir` exists precisely so that no entry needs it.
  escapingPaths = lib.filter (
    path: path == "" || lib.hasPrefix "/" path || lib.elem ".." (lib.splitString "/" path)
  ) paths;

  # These names are also interpolated into the shell below, so anything a shell would read rather
  # than take literally is refused. Escaping instead would make every path in the script unreadable
  # to guard against a name none of these samples has: they are file names from an upstream
  # checkout, which the manifest check holds to that checkout.
  unquotablePaths = lib.filter (path: lib.match "[[:alnum:]_.,+@%^:=/-]*" path == null) paths;

  # `lib.escapeShellArg` leaves an argument alone whenever bash would not split it, and it counts a
  # comma among the characters that need no quoting. Shellcheck then reads the array literal and
  # cannot tell `-roi 0,0,64,64` from a list someone meant to separate with spaces (SC2054) -- and
  # `writeShellApplication` runs shellcheck as its check phase, so that warning fails the build of
  # the tester. Quoting every element unconditionally says what is meant: these arrays are built
  # from Nix lists, where the boundary between one argument and the next is already decided, so
  # there is nothing for bash or for shellcheck to infer.
  quoteShellArgs = lib.concatMapStringsSep " " (arg: "'${lib.replaceString "'" "'\\''" arg}'");

  # Written out rather than passed through `toShellVar` as an array, because each entry is a copy
  # from a store path fixed at build time, and naming both sides in the log is what makes a staging
  # mistake legible.
  stageDataFiles = lib.concatMapAttrsStringSep "\n" (path: source: ''
    echo "staging ${source} as ${path}"
    mkdir --parents "$workRoot/$(dirname ${lib.escapeShellArg path})"
    cp --recursive --dereference --no-target-directory ${lib.escapeShellArg source} "$workRoot/${path}"
    chmod --recursive u+w "$workRoot/${path}"
  '') dataFiles;
in
assert lib.assertMsg (cmdArgs != [ ]) "mkTester: cmdArgs must name an executable to run";
assert lib.assertMsg (escapingPaths == [ ]) (
  "mkTester: ${lib.concatStringsSep ", " escapingPaths} would resolve outside the scratch directory;"
  + " paths must be relative and free of `..`, and a sample which reads from its parent is given a"
  + " workSubdir to run from instead"
);
assert lib.assertMsg (unquotablePaths == [ ]) (
  "mkTester: ${lib.concatStringsSep ", " unquotablePaths} is interpolated into the tester's shell"
  + " and holds a character the shell would act on rather than take as part of a file name"
);
writeShellApplication {
  name = "${cudaNamePrefix}-${component.pname}-tester-${name}";
  inherit runtimeEnv;
  runtimeInputs = [
    sample
    # The staging and the output check below are coreutils; a tester run outside the sandbox should
    # not depend on what happens to be on the caller's PATH.
    coreutils
  ]
  ++ runtimeInputs;
  text = ''
    cmdArgs=(${quoteShellArgs cmdArgs})
    expectedOutputs=(${quoteShellArgs expectedOutputs})

    workRoot="$(mktemp --directory)"
    # `u+w` first: the staged inputs are copies of store paths, so their directories arrive
    # read-only and rm would stop at the first of them.
    trap 'chmod --recursive u+w "$workRoot" && rm --recursive --force "$workRoot"' EXIT

    ${stageDataFiles}

    for expectedOutput in "''${expectedOutputs[@]}"; do
      mkdir --parents "$workRoot/$(dirname "$expectedOutput")"
    done

    mkdir --parents "$workRoot/${workSubdir}"
    cd "$workRoot/${workSubdir}"

    echo "running ''${cmdArgs[*]@Q}"
    "''${cmdArgs[@]}"

    # Reported as a list rather than at the first miss, so that one run says which of the expected
    # outputs are absent instead of naming one and hiding the rest.
    missingOutputs=()
    for expectedOutput in "''${expectedOutputs[@]}"; do
      # Both halves matter: `-s` alone is true of a directory, so a sample which created a directory
      # where a file was expected would pass.
      if ! [[ -f "$workRoot/$expectedOutput" && -s "$workRoot/$expectedOutput" ]]; then
        missingOutputs+=("$expectedOutput")
      fi
    done

    if ((''${#missingOutputs[@]} > 0)); then
      echo "${program} exited successfully without writing: ''${missingOutputs[*]}" >&2
      exit 1
    fi

    if ((''${#expectedOutputs[@]} > 0)); then
      echo "wrote ''${#expectedOutputs[@]} expected output(s): ''${expectedOutputs[*]}"
    fi
  '';
  derivationArgs.postCheck = ''
    if [[ ! -x "${lib.getBin sample}/bin/${program}" ]]; then
      nixErrorLog "${lib.getBin sample} provides no executable named ${program}"
      exit 1
    fi
  '';
  passthru = {
    # Carried through so the derived test can require a builder whose GPU can actually run this.
    minCudaCapability = sample.passthru.minCudaCapability or null;
    # The compiled sample this runs. `mkTest` hangs the tester off the test the same way, so the
    # sample of a test is reachable for building or debugging without being an attribute of the
    # component's `tests`, where it would be neither a test nor something to run on a builder.
    inherit sample;
  };

  meta = {
    description = "Run ${program} from ${sample.pname}";
    # Inherited so a tester for an unfree component is not itself reported as free and portable.
    inherit (component.meta) license platforms;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    teams = component.meta.teams or [ ];
    # A sample which cannot be built here -- because the CUDA version is too old, or no configured
    # capability meets its requirement -- cannot be run here either. The sample's problems are
    # carried over rather than collapsed into a bare `broken`, so the tester reports the same reason,
    # under the same name, as the thing it cannot run. `meta.problems` is deliberately permitted to
    # carry another package's problems verbatim; see `pkgs/stdenv/generic/problems.nix`.
    problems = sample.meta.problems or { } // problems;
  };
}
