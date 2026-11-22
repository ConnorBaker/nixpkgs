{
  backendStdenv,
  cccl,
  cuda_crt,
  cuda_cudart,
  cuda_cuobjdump,
  cuda_nvcc,
  cudaAtLeast,
  cudaOlder,
  flags,
  lib,
  libcurand,
  llvmPackages,
  python3,
  runCommand,
  runCommandCC,
  testers,
}:
# Tests for the nvcc and nvlink wrappers; see README.md.
let
  # nvlink records its command line from CUDA 12.8 for some architectures, including sm_100, and from CUDA 13 for all.
  # The tests link programs without running them, so they use one of those architectures.
  recordsCommandLine = cudaAtLeast "12.8";
  arch = if recordsCommandLine then "sm_100" else lib.head flags.realArches;

  cudadevrtDir = "${lib.getOutput "static" cuda_cudart}/lib";

  # Whether the nvcc wrapper passes --frandom-seed. nvcc has that option from CUDA 12.9.
  seeds = cudaAtLeast "12.9";

  mkTest =
    name: script:
    backendStdenv.mkDerivation {
      __structuredAttrs = true;
      strictDeps = true;

      name = "${cuda_nvcc.name}-${name}";

      inherit arch cudadevrtDir;
      toolkit = cuda_nvcc;
      seeds = lib.boolToString seeds;
      recordsCommandLine = lib.boolToString recordsCommandLine;
      preservesInputNotes = lib.boolToString (cudaAtLeast "13.0");
      checksZeroTimestamp = lib.boolToString (cudaOlder "13.4");

      nativeBuildInputs = [
        cuda_cuobjdump
        cuda_nvcc
      ];

      buildInputs = [ cuda_cudart ];

      dontUnpack = true;
      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        cp ${./tests/kernel.cu} kernel.cu
        cp ${./tests/caller.cu} caller.cu
        cp ${./tests/answer.cu} answer.cu
        cp ${./tests/templates.cu} templates.cu
        cp ${./gpu-check.cu} gpu-check.cu
        source ${./tests/helpers.sh}
      ''
      + script
      + ''
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        [[ ! -e result ]] || cp -v result "$out/"
        runHook postInstall
      '';

      # The directories nvlink records must not become runtime dependencies. (Nix doesn't find references in compressed
      # fatbins, e.g. with -Xfatbin -compress-all, so checkNotes is what checks those.)
      disallowedRequisites = [ cuda_nvcc ] ++ map (output: cuda_cudart.${output}) cuda_cudart.outputs;

      meta = {
        inherit (cuda_nvcc.meta) badPlatforms platforms teams;
      };
    };

  mkScriptTest =
    script:
    mkTest (lib.removeSuffix ".sh" (builtins.baseNameOf script)) ''
      source ${script}
    '';

  mkProcessTest =
    name: command:
    runCommand "${cuda_nvcc.name}-${name}"
      {
        meta = { inherit (cuda_nvcc.meta) badPlatforms platforms teams; };
      }
      ''
        ${command}
        touch "$out"
      '';
in
{
  # nvcc writes the same objects and programs when it runs again.
  nvcc-reproducible = mkScriptTest ./tests/nvcc-reproducible.sh;

  # The cases in which the wrapper does not override the caller.
  nvcc-wrapper = mkScriptTest ./tests/nvcc-wrapper.sh;

  nvcc-process = mkProcessTest "nvcc-process" ''
    ${python3}/bin/python3 -P ${./tests/nvcc-process.py} \
      ${cuda_nvcc.nvccWrapper}/bin/nvcc-wrapper ${./tests/fake-nvcc.py}
  '';
  ptxas-process = mkProcessTest "ptxas-process" ''
    bash ${./tests/ptxas-process.sh} ${cuda_nvcc.ptxasWrapper}/bin/ptxas-wrapper
  '';

  nvcc-ptx-source-paths = mkScriptTest ./tests/nvcc-ptx-source-paths.sh;

  ptxas-lineinfo = mkScriptTest ./tests/ptxas-lineinfo.sh;

  fatbinary-source-paths = mkScriptTest ./tests/fatbinary-source-paths.sh;

  # nvcc runs nvlink for a whole-program link, even without -rdc.
  nvcc-whole-program = mkTest "nvcc-whole-program" ''
    nvcc -arch="$arch" kernel.cu -o result
    checkNotes result
  '';

  # The -L passed by the build is removed along with nvcc's own.
  nvcc-library-dir = mkTest "nvcc-library-dir" ''
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} -o result
    checkNotes result
  '';

  # Nix doesn't find references in a compressed fatbin, so disallowedRequisites can't catch them there; checkNotes reads
  # the notes through cuobjdump, which decompresses them.
  nvcc-compressed = mkTest "nvcc-compressed" ''
    nvcc -arch="$arch" -rdc=true -Xfatbin -compress-all caller.cu answer.cu -L${cudadevrtDir} -o result
    checkNotes result
    options="$(nvlinkOptions result)"
    if [[ -n $options ]] && grep -a -q -F -- "$options" result; then
      nixErrorLog "expected the note in result to be compressed"
      exit 1
    fi
  '';

  # The host linker copies the fatbin, and so the note, as-is.
  nvcc-static-executable =
    (mkTest "nvcc-static-executable" ''
      nvcc -arch="$arch" -rdc=true -Xcompiler -static caller.cu answer.cu -L${cudadevrtDir} -o result
      if readelf --program-headers result | grep -E 'INTERP|DYNAMIC'; then
        nixErrorLog "expected result to be a static executable"
        exit 1
      fi
      # cuobjdump doesn't find the device code in a static executable.
      objcopy --dump-section .nv_fatbin=fatbin result
      checkNotes fatbin
    '').overrideAttrs
      (prevAttrs: {
        buildInputs = prevAttrs.buildInputs ++ [ (lib.getOutput "static" backendStdenv.cc.libc) ];
      });

  # A device-link object in a static library, as from CMake's CUDA_RESOLVE_DEVICE_SYMBOLS.
  nvcc-device-link-object = mkTest "nvcc-device-link-object" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    nvcc -arch="$arch" -dlink caller.o answer.o -L${cudadevrtDir} -o dlink.o
    ar rcs result caller.o answer.o dlink.o
    checkNotes result
  '';

  # nvcc passes long command lines to nvlink in an options file, which names the output (CUDA 12.8 and newer; CUDA 12.6
  # passes them directly).
  nvcc-options-file = mkTest "nvcc-options-file" ''
    libdirs=()
    for i in $(seq 1000); do
      libdirs+=("-L$NIX_BUILD_TOP/a/directory/with/a/long/enough/name/to/make/the/command/line/long/$i")
    done
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} "''${libdirs[@]}" -o result --dryrun 2> dryrun.txt
    ${lib.optionalString recordsCommandLine "grep -F 'nvlink -optf' dryrun.txt"}
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} "''${libdirs[@]}" -o result
    checkNotes result
  '';

  # The wrapper doesn't depend on setup hooks, as with nix develop or a build system outside stdenv.
  nvcc-empty-environment = mkTest "nvcc-empty-environment" ''
    env -i TMPDIR="$TMPDIR" ${lib.getExe cuda_nvcc} -arch="$arch" -rdc=true caller.cu answer.cu \
      ${
        lib.concatMapStringsSep " " (p: "-I${lib.getInclude p}/include") (
          [ cuda_cudart ] ++ lib.optionals (cudaAtLeast "13.0") [ cuda_crt ]
        )
      } \
      -L${cudadevrtDir} -o result
    checkNotes result
  '';

  # nvlink called directly, with each spelling of the output and options files.
  nvlink-output = mkScriptTest ./tests/nvlink-output.sh;

  # CUDA 13's nvlink keeps the notes of the cubins it links, including those of cubins linked without the wrapper, which
  # the wrapper scrubs too.
  nvlink-input-notes = mkScriptTest ./tests/nvlink-input-notes.sh;

  # The wrapper reads the output back, so an output which isn't a regular file fails before nvlink runs.
  nvlink-stream-output = mkTest "nvlink-stream-output" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    # The wrapper would block reading back the output from the pipe.
    expectFailure "/dev/stdout is not a regular file" \
      timeout -s KILL 60 bash -c "nvlink --arch=$arch caller.o answer.o -o /dev/stdout | cat > streamed; exit \''${PIPESTATUS[0]}"
    [[ ! -s streamed ]]
  '';

  # nvlink's errors and exit status are passed through.
  nvlink-error = testers.testBuildFailure' {
    drv = mkTest "nvlink-error" ''
      nvcc -arch="$arch" -rdc=true -c caller.cu
      # Without answer.o.
      nvlink --arch="$arch" caller.o -o result
    '';
    expectedBuilderExitCode = 255;
    expectedBuilderLogEntries = [ "Undefined reference to '_Z6answerv'" ];
  };

  # Check process handling and artifact edits without requiring the vendor toolkit.
  wrapper =
    runCommandCC "${cuda_nvcc.name}-wrapper"
      {
        nativeBuildInputs = [ python3 ];
        meta = { inherit (cuda_nvcc.meta) badPlatforms platforms teams; };
      }
      ''
        nvlinkWrapper=${cuda_nvcc.nvlinkWrapper}/bin/nvlink-wrapper
        storeDir=${lib.escapeShellArg builtins.storeDir}
        fakeNvlink=${./tests/fake-nvlink}
        signalHelper=${./tests/signal.py}
        extendedElf=${./tests/extended-elf.py}
        source ${./tests/helpers.sh}
        source ${./tests/nvlink-process.sh}
        source ${./tests/nvlink-artifacts.sh}
        touch "$out"
      '';
}
// lib.optionalAttrs seeds {
  nvcc-mapped-builds = mkScriptTest ./tests/nvcc-mapped-builds.sh;
}
// lib.optionalAttrs recordsCommandLine {
  # Link-time optimization also records -nvvmpath, which is in cuda_nvcc.
  # NOTE: With caller.cu and answer.cu, only ptxas records its command line.
  nvcc-lto = mkTest "nvcc-lto" ''
    nvcc -arch="$arch" -rdc=true -dlto gpu-check.cu -L${cudadevrtDir} -o result
    checkNotes result
    [[ $(nvlinkOptions result) == *-dlto* ]]
  '';
}
//
  lib.optionalAttrs (cudaAtLeast "12.8" && cudaOlder "13.0" && !backendStdenv.hostPlatform.isx86_64)
    {
      # Clang links relocatable device code by running nvlink from its CUDA path, through clang-nvlink-wrapper, which
      # also passes Clang's own library directory.
      # NOTE: Clang 21 fails to parse CUDA 13's headers. On x86_64, the Clang wrapper passes -mtls-dialect=gnu2, which
      # Clang rejects for the device code.
      clang-gpu-rdc =
        let
          clang = llvmPackages.clang;
        in
        (mkTest "clang-gpu-rdc" ''
          # A CUDA installation laid out as Clang expects, linking to the wrapper as cudatoolkit does.
          toolkit=$PWD/toolkit
          mkdir -p "$toolkit/bin" "$toolkit/include"
          ln -s ${cuda_nvcc}/bin/{*,.nvlink-wrapped} "$toolkit/bin/"
          ln -s ${cuda_nvcc}/nvvm "$toolkit/nvvm"
          ln -s ${lib.getLib cuda_cudart}/lib "$toolkit/lib64"
          for dir in ${
            lib.concatMapStringsSep " " (p: "${lib.getInclude p}/include") [
              cccl
              cuda_cudart
              cuda_nvcc
              libcurand
            ]
          }; do
            ln -sf "$dir"/* "$toolkit/include/"
          done
          ${lib.getExe' clang "clang++"} -x cuda --cuda-path="$toolkit" --offload-arch="$arch" --offload-new-driver \
            -fgpu-rdc -Wno-unknown-cuda-version caller.cu answer.cu \
            -L${cudadevrtDir} -lcudart_static -ldl -lrt -lpthread \
            -o result
          checkNotes result
        '').overrideAttrs
          (prevAttrs: {
            # Clang applies them to the device code too, for which some (e.g. zerocallusedregs) are unsupported.
            hardeningDisable = [ "all" ];
            disallowedRequisites = prevAttrs.disallowedRequisites ++ [ clang.cc ];
          });
    }
