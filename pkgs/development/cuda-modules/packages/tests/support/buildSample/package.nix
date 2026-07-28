# Builds a single sample project from one of NVIDIA's sample repositories.
#
# Repositories like `CUDALibrarySamples` ship one self-contained CMake project per example rather
# than a single build covering them all, and the leaves refer to paths like
# `${CMAKE_SOURCE_DIR}/../utils`, so they cannot be aggregated with `add_subdirectory` anyway.
# One derivation per project follows that grain: a project which fails to compile takes down only
# its own tests, projects build in parallel, and each caches independently.
#
# Samples are built separately from the component they exercise -- a redistributable is unpacked
# rather than compiled, so nothing can be built inside it -- and separately from the testers which
# run them, so that changing an invocation does not force a recompile.
{
  backendStdenv,
  cmake,
  cuda_cuobjdump,
  cuda_nvcc,
  cudaAtLeast,
  cudaMajorMinorVersion,
  cudaNamePrefix,
  flags,
  jq,
  lib,
}:
{
  # The component these samples exercise. Supplies the version and the licensing metadata, which
  # would otherwise claim these binaries are freely redistributable.
  component,

  src,

  # Path of the project within the source, e.g. "cuBLAS/Level-3/gemm".
  sampleRoot,

  # Executables the project is expected to produce. Installing by name rather than by scraping the
  # build tree means an upstream rename fails here, on any builder, rather than silently surviving
  # until someone runs the tests on a machine with a GPU.
  programs,

  # programsWithDeviceCodeFromPrebuiltLibrary :: [String]
  # Executables among `programs` whose device code this build does not compile at all, but links in
  # from a library which was built elsewhere. cuSPARSELt's `*_static` programs take theirs from
  # `libcusparseLt_static.a`, which carries the SASS NVIDIA chose to ship -- 52 80 86 87 89 90 90a
  # 100 103 120 120f 121, and not the 75 this package set asks for -- so what `cuobjdump` reads back
  # out of those binaries describes that library rather than this build's request, and requiring it
  # to equal the request fails a build which compiled, linked and installed exactly what it should.
  #
  # Named one executable at a time, rather than as a property of the project, because that is how
  # narrow the situation is: the dynamically linked programs built from those same sources embed no
  # device code whatsoever, and the check below would catch them the day they started to.
  #
  # This is not `doInstallCheck = false`, and not a way to quieten a sample whose architectures
  # disagree with the request for reasons of its own. Everything the check can still say is still
  # required: `cuobjdump` must succeed, the binary must contain device code -- one declared to carry
  # a library's fatbins and found to carry none is a stale declaration, not one to wave through --
  # and what it does contain is logged as for every other program, with a line saying it was not
  # required to match. An opt-out which goes quiet is how the `cuobjdump` skip on this branch became
  # vacuous once already: an empty result was taken for proof of host-only code, and 72 binaries
  # passed unexamined because `cuobjdump` was not on PATH.
  programsWithDeviceCodeFromPrebuiltLibrary ? [ ],

  # Requirements, curated per sample rather than generated: upstream states them unreliably (most
  # READMEs say "All GPUs supported by CUDA Toolkit", the enumerated ones are stale, and cuBLASLt has
  # no READMEs at all), and no sample guards against them at runtime.
  #
  # minCudaVersion :: null | String -- lowest CUDA version whose libraries expose the APIs used.
  minCudaVersion ? null,
  # maxCudaVersion :: null | String -- highest CUDA version the sample still compiles against. The
  # samples are a rolling checkout of upstream's repository while the toolkit is versioned, so a
  # sample can be left behind by a signature change rather than by a missing API: NPP's
  # `nppiSegmentWatershedGetBufferSize_8u_C1R` took an `int *` up to libnpp 12.3.1.54 and takes a
  # `size_t *` from 12.3.3.100 on, and the sample was never updated. Inclusive, and measured by
  # building against each package set rather than read off a header.
  maxCudaVersion ? null,
  # minCudaCapability :: null | String -- lowest compute capability the sample can run on, e.g. the
  # FP8 matmuls need "8.9" and the narrow-precision ones need Blackwell.
  minCudaCapability ? null,

  pname ? "${component.pname}-sample-${baseNameOf sampleRoot}",
  version ? component.version,

  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  cmakeFlags ? [ ],
  postPatch ? "",
  meta ? { },
  ...
}@args:
let
  # Capabilities this sample can run on, given both what it needs and what the package set is
  # configured to build for. The sample is built for exactly these.
  usableCudaCapabilities =
    if minCudaCapability == null then
      backendStdenv.cudaCapabilities
    else
      lib.filter (
        capability: lib.versionAtLeast capability minCudaCapability
      ) backendStdenv.cudaCapabilities;

  # Requirements are reported through meta.problems rather than a bare meta.broken, so that the
  # reason a sample is unavailable -- and the values which failed to satisfy it -- are legible
  # without reading this file.
  problems =
    lib.optionalAttrs (minCudaVersion != null && !(cudaAtLeast minCudaVersion)) {
      cudaVersionTooOld = {
        kind = "broken";
        message =
          "Sample ${sampleRoot} requires CUDA ${minCudaVersion} or newer,"
          + " but this package set provides ${cudaMajorMinorVersion}.";
      };
    }
    //
      lib.optionalAttrs
        (maxCudaVersion != null && !(lib.versionAtLeast maxCudaVersion cudaMajorMinorVersion))
        {
          cudaVersionTooNew = {
            kind = "broken";
            message =
              "Sample ${sampleRoot} was last able to build against CUDA ${maxCudaVersion},"
              + " but this package set provides ${cudaMajorMinorVersion}.";
          };
        }
    // lib.optionalAttrs (usableCudaCapabilities == [ ]) {
      noUsableCudaCapability = {
        kind = "broken";
        message =
          "Sample ${sampleRoot} requires compute capability ${minCudaCapability} or newer,"
          + " but the configured capabilities are"
          + " ${lib.concatStringsSep ", " backendStdenv.cudaCapabilities}.";
      };
    };

  # Everything said about this sample being unavailable here, from both sources: the requirements
  # above and whatever the component's package.nix measured. `certifyPrograms` needs the whole set,
  # because whether a project which will not build can still be *configured* is exactly what decides
  # how its program list can be checked.
  allProblems = problems // meta.problems or { };
in
backendStdenv.mkDerivation (
  finalAttrs:
  lib.removeAttrs args [
    "component"
    "sampleRoot"
    "programs"
    "programsWithDeviceCodeFromPrebuiltLibrary"
    "minCudaVersion"
    "maxCudaVersion"
    "minCudaCapability"
  ]
  // {
    __structuredAttrs = true;
    strictDeps = true;

    name = "${cudaNamePrefix}-${finalAttrs.pname}-${finalAttrs.version}";
    inherit pname version src;

    nativeBuildInputs = [
      cmake
      cuda_nvcc
      # Used to prove the binaries really were built for the requested capabilities.
      cuda_cuobjdump
    ]
    ++ nativeBuildInputs;

    buildInputs = [ component ] ++ buildInputs;

    # We configure the project ourselves so that CMAKE_SOURCE_DIR lands on the project rather than
    # on the checkout root, which is what the leaves expect.
    dontUseCmakeConfigure = true;

    cmakeFlags = [
      (lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release")
      (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" (
        lib.concatStringsSep ";" (map flags.dropDots usableCudaCapabilities)
      ))
    ]
    ++ cmakeFlags;

    inherit sampleRoot programs;
    expectedArchitectures = map flags.dropDots usableCudaCapabilities;

    # CMake commands are case-insensitive and the sample trees are inconsistent about case, so every
    # pattern below is matched case-insensitively. Each rewrite reports what it touched: a rewrite
    # which silently stops applying after an upstream reformat would resurface as a confusing
    # compiler error much later.
    postPatch = ''
      # The per-library helpers live beside the projects rather than inside them --
      # `cuBLAS/cmake/cublas_example.cmake` serves every project under `cuBLAS` -- and a project
      # picks them up with `include()`, so a `set()` or a `set_property()` in a helper takes effect
      # on this build exactly as one in the project's own CMakeLists.txt does. Both rewrites below
      # therefore range over the same files: every `CMakeLists.txt` and every `*.cmake` in the
      # subtree the project belongs to, not just the project directory. Scoping either of them
      # narrower would leave the shared helper -- the file most likely to acquire the construct
      # being rewritten, since it is the one upstream edits once for a whole library -- untouched,
      # and the rewrite would report nothing while quietly not applying. Rewriting files belonging
      # to sibling projects costs nothing, because only this project is ever configured.
      local sampleSubtree="''${sampleRoot%%/*}"

      local cmakeFilePath=""
      local -i patchedOverride=0
      while IFS= read -r -d $'\0' cmakeFilePath; do
        # Many projects pin themselves to C++11, which nvcc can no longer use to parse the libstdc++
        # headers shipped with the host compiler backendStdenv selects -- it reports errors on
        # builtins such as `__is_nothrow_new_constructible`. The pin is a plain `set()` rather than a
        # cache entry, so it shadows `-DCMAKE_CUDA_STANDARD=17` and has to be rewritten in place.
        # Written with a tolerant amount of whitespace: cuDSS aligns its values
        # (`set(CMAKE_CUDA_STANDARD          11)`), and a pattern assuming a single space silently
        # skipped it, which surfaced much later as an unreadable wall of libstdc++ errors.
        if grep --quiet --extended-regexp --ignore-case \
          'set\(CMAKE_(CXX|CUDA)_STANDARD[[:space:]]+11[[:space:]]*\)' "$cmakeFilePath"; then
          nixLog "raising the C++ standard pinned by $cmakeFilePath from 11 to 17"
          sed --regexp-extended --in-place \
            's/set\(CMAKE_(CXX|CUDA)_STANDARD[[:space:]]+11[[:space:]]*\)/set(CMAKE_\1_STANDARD 17)/I' \
            "$cmakeFilePath"
        fi

        # The per-library example helpers -- add_cublas_example and friends -- set
        # CUDA_ARCHITECTURES OFF on every target, which overrides CMAKE_CUDA_ARCHITECTURES and
        # leaves the sample compiled for nvcc's default architecture alone. Without this the
        # requested capabilities are silently ignored; installCheckPhase asserts the result.
        if grep --quiet --ignore-case 'PROPERTY CUDA_ARCHITECTURES OFF' "$cmakeFilePath"; then
          nixLog "removing the CUDA_ARCHITECTURES override in $cmakeFilePath"
          sed --regexp-extended --in-place \
            '/set_property\(TARGET .+ PROPERTY CUDA_ARCHITECTURES OFF\)/Id' \
            "$cmakeFilePath"
          patchedOverride=1
        fi
      done < <(
        find "''${sampleSubtree:?}" -type f \( -name CMakeLists.txt -o -name '*.cmake' \) -print0
      )

      if ((patchedOverride)); then
        nixLog "patched a CUDA_ARCHITECTURES override; installCheckPhase will confirm the result"
      fi
    ''
    + postPatch;

    buildPhase = ''
      runHook preBuild

      nixLog "configuring sample project ''${sampleRoot:?}"
      # cmakeFlagsArray carries flags added by setup hooks at preConfigure time, such as
      # setupCudaHook's CUDAToolkit_ROOT; the cmake setup hook would pass both arrays for us, but we
      # bypass it in order to point CMake at the project rather than at the checkout root.
      #
      # Both are expanded plainly. `set -u` is in force here -- stdenv's setup.sh sets it -- but
      # since bash 4.4 `"''${arr[@]}"` yields nothing for an array which is empty *or* unset rather
      # than tripping it, and nothing in Nixpkgs runs an older bash. Only a subscripted reference
      # such as `''${arr[0]}` still needs guarding, and there is none here.
      cmake -S "''${sampleRoot:?}" -B build \
        "''${cmakeFlags[@]}" \
        "''${cmakeFlagsArray[@]}"

      nixLog "building sample project ''${sampleRoot:?}"
      cmake --build build --parallel "''${NIX_BUILD_CORES:?}"

      runHook postBuild
    '';

    # `programs` is checked in both directions, so the set of executables this project is expected to
    # produce is exact. Declared-but-missing catches an upstream rename or removal; produced-but-
    # undeclared catches an upstream addition, which would otherwise be silently left untested --
    # `cuBLAS/Level-1/dot`, for instance, builds both `cublas_dot_example` and `cublas_dotc_example`.
    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"

      local program=""
      local programPath=""
      for program in "''${programs[@]}"; do
        programPath="$(find build -type f -executable -name "$program" -not -path '*/CMakeFiles/*' -print -quit)"
        if [[ -z $programPath ]]; then
          nixErrorLog "sample project ''${sampleRoot:?} declares $program in programs but did not produce it"
          exit 1
        fi
        nixLog "installing sample executable $program"
        install -Dm755 "$programPath" "$out/bin/$program"
      done

      local -a undeclared=()
      while IFS= read -r -d $'\0' programPath; do
        program="$(basename "$programPath")"
        if [[ " ''${programs[*]} " != *" $program "* ]]; then
          undeclared+=("$program")
        fi
      done < <(
        find build -type f -executable -not -path '*/CMakeFiles/*' -not -name '*.so*' -print0 |
          sort --zero-terminated
      )

      if ((''${#undeclared[@]} > 0)); then
        nixErrorLog "sample project ''${sampleRoot:?} produced executables missing from programs: ''${undeclared[*]}"
        exit 1
      fi

      runHook postInstall
    '';

    # Requesting a capability and compiling for it are different things: a per-target
    # CUDA_ARCHITECTURES override silently discards the request, which is how the whole cuBLAS tree
    # came to be built for sm_52 alone. Reading the architectures back out of the binaries is the
    # only check that cannot be fooled by a flag which was accepted and ignored.
    #
    # The comparison is exact in both directions. Checking only that the requested architectures are
    # present accepts a build which additionally embeds architectures nobody asked for -- a
    # CMakeLists appending its own `--generate-code`, or a static library dragging in its own
    # fatbins -- which inflates the binary and hides that the request is not what was honoured.
    #
    # SASS and PTX are counted separately, because they are not interchangeable here. `cuobjdump`
    # reports `arch = sm_NN` under both `Fatbin elf code:` (compiled SASS) and `Fatbin ptx code:`
    # (PTX for the driver to JIT), so a build which produced PTX alone would satisfy a check that did
    # not distinguish them while having compiled nothing for the device. These binaries exist to be
    # run on a specific GPU, so every requested capability must be present as SASS. PTX for a
    # requested capability is expected -- a bare `CMAKE_CUDA_ARCHITECTURES` entry such as `90` asks
    # CMake for `compute_90` as well as `sm_90` -- but PTX for anything else is a discarded request
    # just as surely as unexpected SASS is.
    #
    # This is exact for device code the CUDA compiler embedded, and blind to device code a project
    # generated for itself. `cuFFT/lto_callback_window_1d` and `cuFFT/lto_ea` compile their window
    # callback in an `add_custom_command` pinned to `arch=compute_60,code=lto_60`, pass the fatbin
    # through `bin2c`, and include the result as a C array: `cuobjdump` sees an array of integers, so
    # both report exactly the requested architectures and pass while the callback inside them stays
    # at compute_60 whatever `cudaCapabilities` says. Rewriting that pin is not a change to make
    # unverified -- the fatbin holds LTO IR which nvJitLink links against cuFFT at run time, not SASS
    # the loader can use, so the correct value is not simply the requested capability -- so the scan
    # at the end of this phase names the lines which compile device code out of CMake's sight rather
    # than letting a passing log imply a coverage this cannot deliver.
    #
    # The comparison is dropped for a binary named in `programsWithDeviceCodeFromPrebuiltLibrary`,
    # whose device code NVIDIA compiled; see the note on that argument. Dropped, not skipped: such a
    # binary is still dumped, still required to contain device code, and has what it does contain
    # logged with a line saying it was not required to match.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      local checkDir=""
      checkDir="$(mktemp --directory)"

      # `cuobjdump` reports "no architectures" in two ways which must not be conflated. A binary
      # holding no device code at all writes `does not contain device code` to stderr, nothing to
      # stdout, and exits non-zero (255 on both CUDA 12 and CUDA 13); a genuine failure -- an
      # unreadable or corrupt binary, or `cuobjdump` missing from PATH -- also writes nothing to
      # stdout and also exits non-zero, saying something else. Emptiness alone therefore separates
      # nothing, and the pipeline this replaces could not even see the exit status: the status of a
      # process substitution is not the parent's, so `mapfile -t sass < <(cuobjdump ... | awk ...)`
      # turned every failure into two empty arrays. Dropping `cuda_cuobjdump` from
      # `nativeBuildInputs` was enough to make a sample built for sm_52 alone report "contains no
      # device code" and install successfully -- exactly the regression the paragraph above claims
      # this check cannot be fooled by. Nothing below concludes anything from an empty result; the
      # exit status and the diagnostics decide.
      #
      # Writes cuobjdump's report on a binary to $checkDir/dump and its diagnostics to
      # $checkDir/diagnostics, and returns cuobjdump's own exit status.
      cudaSampleDumpDeviceCode() {
        cuobjdump "''${1:?}" >"$checkDir/dump" 2>"$checkDir/diagnostics"
      }

      # Architectures appearing in the fatbin sections of one kind, `elf` (SASS) or `ptx`, of the
      # dump cudaSampleDumpDeviceCode last wrote, deduplicated into $checkDir/$kind. Landing in a
      # file rather than on standard output keeps a failure of `awk` or of `sort` a failure of this
      # function, rather than an empty result indistinguishable from a clean parse.
      cudaSampleArchitecturesOfKind() {
        local -r kind="''${1:?}"
        awk -v kind="$kind" '
          /^Fatbin elf code:/ { section = "elf"; next }
          /^Fatbin ptx code:/ { section = "ptx"; next }
          section == kind && /^arch = sm_/ { sub(/^arch = sm_/, ""); print }
        ' "$checkDir/dump" >"$checkDir/$kind" || return
        sort --unique --output "$checkDir/$kind" "$checkDir/$kind"
      }

      local program=""
      local diagnostic=""
      local -a sass=()
      local -a ptx=()
      local -a missing=()
      local -a unexpectedSass=()
      local -a unexpectedPtx=()
      local -a handWritten=()
      local handWrittenLine=""
      local architecture=""
      local -i failed=0
      local -i dumpStatus=0
      local -i scanStatus=0
      local -i fromPrebuiltLibrary=0
      local -a undeclaredPrebuilt=()

      # `programsWithDeviceCodeFromPrebuiltLibrary` reaches the builder only on the samples which
      # declare one -- it is added with `lib.optionalAttrs`, so that naming no program leaves the
      # derivation exactly as it was rather than adding an empty attribute to every sample's hash.
      # It is therefore copied once into an array which always exists, so the rest of this phase can
      # read it plainly instead of repeating an expansion which tolerates its absence.
      local -a prebuiltDeviceCodePrograms=(
        ''${programsWithDeviceCodeFromPrebuiltLibrary[@]+"''${programsWithDeviceCodeFromPrebuiltLibrary[@]}"}
      )

      # A name in it which this project does not build is a typo, and a typo here is silent in the
      # direction that matters least -- the check simply stays on -- but it also means the executable
      # someone meant to name is still being compared against a request its device code never saw,
      # so it is reported rather than left to be diagnosed through a confusing architecture mismatch.
      for program in "''${prebuiltDeviceCodePrograms[@]}"; do
        if [[ " ''${programs[*]} " != *" $program "* ]]; then
          undeclaredPrebuilt+=("$program")
        fi
      done

      if ((''${#undeclaredPrebuilt[@]} > 0)); then
        nixErrorLog "programsWithDeviceCodeFromPrebuiltLibrary names ''${undeclaredPrebuilt[*]}, which"
        nixErrorLog "sample project ''${sampleRoot:?} does not build; its programs are: ''${programs[*]}"
        exit 1
      fi

      # The requested architectures, put through the same `sort` as the two files
      # `cudaSampleArchitecturesOfKind` writes, so that the set differences below compare two sides
      # ordered by one rule. Written from a loop rather than `printf '%s\n' "''${arr[@]}"` because
      # printf given no arguments still emits one empty line, which would become a requested
      # architecture named "".
      for architecture in "''${expectedArchitectures[@]}"; do printf '%s\n' "$architecture"; done \
        | sort --unique >"$checkDir/expected"

      for program in "''${programs[@]}"; do
        fromPrebuiltLibrary=0
        if [[ " ''${prebuiltDeviceCodePrograms[*]} " == *" $program "* ]]; then
          fromPrebuiltLibrary=1
        fi

        dumpStatus=0
        cudaSampleDumpDeviceCode "$out/bin/$program" || dumpStatus=$?

        # Some samples are pure host code -- every cuSPARSE project, most cuRAND host examples and
        # two nvJPEG decoders call only library entry points and compile nothing of their own -- so
        # they legitimately embed nothing, and cuobjdump says so in as many words. That statement,
        # rather than an empty dump, is what licenses skipping the comparison.
        if grep --quiet --fixed-strings 'does not contain device code' "$checkDir/diagnostics"; then
          # A program declared to be carrying device code from a prebuilt library, and carrying none,
          # is a declaration which no longer describes the binary: the library it was linked against
          # stopped supplying fatbins, or the program stopped linking it. Either way the reason this
          # binary is exempt from the comparison has ceased to hold, so it is not exempt.
          if ((fromPrebuiltLibrary)); then
            nixErrorLog "$program is declared to take its device code from a prebuilt library, yet"
            nixErrorLog "cuobjdump reports it contains no device code at all; the declaration is stale"
            exit 1
          fi
          nixLog "$program contains no device code, as cuobjdump reports; nothing to check"
          continue
        fi

        if ((dumpStatus != 0)); then
          nixErrorLog "cuobjdump exited with status $dumpStatus on $program, so the architectures it"
          nixErrorLog "was built for could not be read back and nothing about it has been checked:"
          while IFS= read -r diagnostic; do
            nixErrorLog "  $diagnostic"
          done <"$checkDir/diagnostics"
          exit 1
        fi

        if ! cudaSampleArchitecturesOfKind elf || ! cudaSampleArchitecturesOfKind ptx; then
          nixErrorLog "could not parse cuobjdump's report on $program"
          exit 1
        fi
        mapfile -t sass <"$checkDir/elf"
        mapfile -t ptx <"$checkDir/ptx"
        nixLog "$program embeds SASS for: ''${sass[*]-none}; PTX for: ''${ptx[*]-none}"

        # cuobjdump succeeded, which means it found a fatbin and did not call the binary free of
        # device code. A fatbin naming no architecture at all is then something this does not know
        # how to read, not something to wave through.
        if ((''${#sass[@]} == 0 && ''${#ptx[@]} == 0)); then
          nixErrorLog "cuobjdump succeeded on $program yet named no architecture, while also not"
          nixErrorLog "reporting the binary as free of device code; refusing to guess which it is"
          exit 1
        fi

        # The architectures above were logged before this point, and the checks above were run,
        # precisely so that this exemption leaves a record of what it declined to compare rather
        # than an attribute somewhere stating that something was not looked at.
        if ((fromPrebuiltLibrary)); then
          nixLog "$program takes its device code from a prebuilt library rather than compiling it"
          nixLog "here, so the architectures above were not required to match the requested"
          nixLog "''${expectedArchitectures[*]}; they are the ones that library was shipped with"
          continue
        fi

        # The three comparisons are one operation asked three ways -- what was requested and is not
        # present as SASS, and what is present as SASS or as PTX without having been requested --
        # so they are set differences rather than three transcriptions of the same nested loop.
        # `cudaSampleArchitecturesOfKind` already left each side sorted and deduplicated in a file,
        # which is what `comm` needs; the requested list is put through the same `sort` so that the
        # two sides are ordered by the same rule.
        mapfile -t missing < <(comm -23 "$checkDir/expected" "$checkDir/elf")
        mapfile -t unexpectedSass < <(comm -13 "$checkDir/expected" "$checkDir/elf")
        mapfile -t unexpectedPtx < <(comm -13 "$checkDir/expected" "$checkDir/ptx")

        if ((''${#missing[@]} > 0)); then
          nixErrorLog "$program embeds no SASS for requested architectures: ''${missing[*]}"
          for architecture in "''${missing[@]}"; do
            if [[ " ''${ptx[*]-} " == *" $architecture "* ]]; then
              nixErrorLog "  $architecture is present as PTX only, which the tests cannot rely on"
            fi
          done
          failed=1
        fi

        if ((''${#unexpectedSass[@]} > 0)); then
          nixErrorLog "$program embeds SASS for unrequested architectures: ''${unexpectedSass[*]}"
          failed=1
        fi

        if ((''${#unexpectedPtx[@]} > 0)); then
          nixErrorLog "$program embeds PTX for unrequested architectures: ''${unexpectedPtx[*]}"
          failed=1
        fi

        if ((failed)); then
          nixErrorLog "requested architectures were: ''${expectedArchitectures[*]}"
          nixErrorLog "$program embeds SASS for: ''${sass[*]-none}; PTX for: ''${ptx[*]-none}"
          exit 1
        fi
      done

      # Device code the project compiled itself, by driving nvcc from a rule of its own rather than
      # by declaring a CUDA source and letting CMake pass CUDA_ARCHITECTURES down, is outside
      # everything above -- see the note on hand-written fatbins. Report the lines which do it, so
      # that a build log records what was not verified instead of letting the lines above stand for
      # the whole binary. The architecture is matched loosely because upstream writes it through a
      # variable (`arch=compute_''${CUDA_LTO_ARCHITECTURE}`) rather than as a literal, so the flag
      # rather than its expansion is what can be recognised here.
      grep --recursive --line-number --extended-regexp \
        --include=CMakeLists.txt --include='*.cmake' \
        '(^|[[:space:]])(-gencode|--generate-code)([[:space:]]|=)' "''${sampleRoot:?}" \
        >"$checkDir/handWritten" || scanStatus=$?
      # grep exits 1 when nothing matches, which is the ordinary case here; anything above that is a
      # scan which did not run, and must not be reported as a scan which found nothing.
      if ((scanStatus > 1)); then
        nixErrorLog "scanning ''${sampleRoot:?} for hand-written architecture specifications failed with exit status $scanStatus"
        exit 1
      fi
      sort --unique --output "$checkDir/handWritten" "$checkDir/handWritten"
      mapfile -t handWritten <"$checkDir/handWritten"

      if ((''${#handWritten[@]} > 0)); then
        nixLog "''${sampleRoot:?} compiles device code outside the fatbins the CUDA compiler embeds:"
        for handWrittenLine in "''${handWritten[@]}"; do
          nixLog "  $handWrittenLine"
        done
        nixLog "cuobjdump cannot read that code back, so the architectures checked above do not cover it"
      fi

      rm --recursive --force "$checkDir"
      # The variables above are `local` to the function stdenv runs this phase in and go out of
      # scope with it; the two helpers are not, so only they need clearing.
      unset -f cudaSampleDumpDeviceCode cudaSampleArchitecturesOfKind

      runHook postInstallCheck
    '';

    passthru = {
      # Surfaced so consumers can report why a sample is unavailable, and so the derived test can
      # require a builder whose GPU is able to run it.
      inherit
        minCudaVersion
        maxCudaVersion
        minCudaCapability
        usableCudaCapabilities
        ;

      # `programs` checked against CMake's own answer, rather than against the binaries a build
      # produced.
      #
      # `installPhase` above already compares `programs` to what landed in the build tree, exactly
      # and in both directions, and that is the stronger check -- it sees what was actually made. But
      # it runs only for a project which compiles, and the program lists least worth trusting belong
      # to the projects which do not: nvCOMP's two are written against an API nvCOMP 5.0.0.6 renamed,
      # so nothing had ever compared their lists against anything, and both turned out to be wrong in
      # both directions at once.
      #
      # It is asked of CMake, configured exactly as the real build configures it, rather than read
      # off the CMakeLists by any means whatsoever: which executables a project builds is a function
      # of its sources and of this derivation's inputs together, and `manifest.py`'s header works the
      # example that settled it.
      #
      # This configures and stops; it compiles nothing and needs no GPU. `meta.problems` is cleared
      # so that a sample which cannot be *built* here is still asked about, which is the entire
      # point: nvCOMP's two configure perfectly well and only fail to compile.
      #
      # Configuring is not always what remains possible, though, and assuming it was is a mistake
      # this made once. A requirement can stop CMake before it defines a single target:
      # `nvJPEG/nvJPEG-Encoder-MultipleInstances` opens with `find_package(CUDAToolkit 12.9)` and on
      # CUDA 12.6 configure ends at "Could NOT find CUDAToolkit: Found unsuitable version 12.6.85,
      # but required is at least 12.9". So the two outcomes are read against what is already known
      # about the sample:
      #
      # *   Configure succeeded -- certify, whatever `problems` says. Always the stronger answer.
      # *   Configure failed, and something already records that this sample does not work here --
      #     report that, and pass. Nothing is being hidden: the sample is already marked unavailable,
      #     for a reason someone measured and wrote down.
      # *   Configure failed with nothing recorded -- fail. A project which is supposed to work here
      #     and cannot even be configured is a defect, not a certification outcome.
      #
      # This is per-package-set by construction, which a hand-written list of exceptions could not
      # be: the same project configures on one package set and not on another, and which is which is
      # already stated by the requirements the component measured.
      certifyPrograms = finalAttrs.finalPackage.overrideAttrs (prevAttrs: {
        pname = "${prevAttrs.pname}-programs";

        nativeBuildInputs = prevAttrs.nativeBuildInputs ++ [ jq ];

        buildPhase = ''
          runHook preBuild

          # The query has to exist before CMake runs: the reply is written during configure, and one
          # added afterwards yields nothing until the next configure.
          mkdir -p build/.cmake/api/v1/query
          : > build/.cmake/api/v1/query/codemodel-v2

          # Not allowed to fail the build here; installPhase is where the outcomes are read.
          nixLog "configuring sample project ''${sampleRoot:?} to certify its program list"
          configureStatus=0
          cmake -S "''${sampleRoot:?}" -B build \
            "''${cmakeFlags[@]}" \
            "''${cmakeFlagsArray[@]}" || configureStatus=$?

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p "$out"

          if ((configureStatus != 0)); then
          ${
            if allProblems == { } then
              ''
                nixErrorLog "sample project ''${sampleRoot:?} could not be configured, so CMake was never"
                nixErrorLog "able to say what it builds. Nothing records this sample as unavailable here,"
                nixErrorLog "so this is a defect to fix rather than a certification outcome."
                exit "$configureStatus"
              ''
            else
              # Through a variable rather than interpolated into each message: these messages quote
              # the CMake errors they describe, and a `"` spliced into a double-quoted string ends it
              # -- which silently ate the quotes out of cuDSS's message the first time this was
              # written.
              ''
                reason=${
                  lib.escapeShellArg (
                    lib.concatStringsSep "\n" (
                      lib.mapAttrsToList (name: problem: "${name}: ${problem.message}") allProblems
                    )
                  )
                }
                nixLog "''${sampleRoot:?} could not be configured here, so CMake never named an executable"
                nixLog "and its program list rests on nothing this package set can check. That is"
                nixLog "expected -- this sample is already recorded as unavailable here:"
                printf '%s\n' "$reason" | while IFS= read -r line; do nixLog "  $line"; done
                printf '%s\n' "$reason" >"$out/uncertifiable"
              ''
          }
          else
            # Read through the codemodel's own target list rather than by globbing `target-*.json`.
            # The reply directory also holds a file for each imported executable CMake defined along
            # the way -- FindCUDAToolkit's `CUDA::bin2c` is one, an EXECUTABLE whose `sources` are
            # empty -- and no project builds those. The codemodel lists the buildsystem's targets and
            # only those, which is the distinction being drawn here.
            replyDir="build/.cmake/api/v1/reply"
            jq --raw-output '.configurations[].targets[].jsonFile' "$replyDir"/codemodel-v2-*.json \
              | while IFS= read -r targetFile; do
                  jq --raw-output 'select(.type == "EXECUTABLE") | .name' "$replyDir/$targetFile"
                done \
              | sort --unique >"$out/built"

            # Written from a loop for the reason given in installCheckPhase: printf with no arguments
            # still emits one empty line, which would become a declared program named "".
            for program in "''${programs[@]}"; do printf '%s\n' "$program"; done \
              | sort --unique >"$out/declared"

            missing=()
            undeclared=()
            mapfile -t missing < <(comm -23 "$out/declared" "$out/built")
            mapfile -t undeclared < <(comm -13 "$out/declared" "$out/built")

            if ((''${#missing[@]} > 0)); then
              nixErrorLog "programs declares ''${missing[*]}, which CMake does not build here"
            fi
            if ((''${#undeclared[@]} > 0)); then
              nixErrorLog "CMake builds ''${undeclared[*]}, which programs does not declare"
            fi
            if ((''${#missing[@]} + ''${#undeclared[@]} > 0)); then
              nixErrorLog "the manifest's program list for ''${sampleRoot:?} does not describe this build"
              exit 1
            fi

            nixLog "certified ''${#programs[@]} programs for ''${sampleRoot:?} against CMake"
          fi

          runHook postInstall
        '';

        # Nothing was compiled, so there is no binary to read architectures back out of.
        doInstallCheck = false;

        meta = prevAttrs.meta // {
          description = "Programs declared for sample ${sampleRoot}, checked against CMake's target list";
          problems = { };
        };
      });
    }
    // args.passthru or { };

    meta = {
      # Inherited so these binaries do not advertise themselves as more freely redistributable, or
      # more portable, than the component they link against.
      inherit (component.meta) license platforms;
      teams = component.meta.teams or [ ];
      sourceProvenance = [ lib.sourceTypes.fromSource ];
      description =
        "Sample ${sampleRoot} built against ${component.pname}"
        + lib.optionalString (minCudaVersion != null) " (requires CUDA >= ${minCudaVersion})"
        + lib.optionalString (maxCudaVersion != null) " (requires CUDA <= ${maxCudaVersion})"
        + lib.optionalString (minCudaCapability != null) " (requires SM >= ${minCudaCapability})";
    }
    // meta
    // {
      problems = allProblems;
    };
  }
  # Carried only by the samples which declare one, rather than as an empty list on all of them: a
  # sample which compiles its own device code says nothing by carrying an empty exemption, and the
  # derivation of the overwhelming majority which never use this stays as it was. installCheckPhase
  # therefore reads it through expansions which tolerate the variable not existing.
  // lib.optionalAttrs (programsWithDeviceCodeFromPrebuiltLibrary != [ ]) {
    inherit programsWithDeviceCodeFromPrebuiltLibrary;
  }
)
