{
  autoAddCudaCompatRunpath,
  buildEnv,
  buildPackages,
  callPackage,
  cudaDriverSelector,
  lib,
  pythonDriverLookup,
  runCommandCC,
  stdenv,
}:
let
  # Each fixture is a separate ELF executable or shared object at the system loader boundary.
  fixtures = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "rs") ./.;
  };
  rustc = ''${buildPackages.rustc}/bin/rustc --edition=2024 --target=${stdenv.hostPlatform.rust.rustcTargetSpec} -Clinker="$CC" -Cpanic=abort -Copt-level=2'';
  shared = "${rustc} --crate-type=cdylib";
  selector = cudaDriverSelector.override { hostRoot = "."; };
  python = buildPackages.python3.withPackages (ps: [ ps.pyelftools ]);
  redistSystem = if stdenv.hostPlatform.isAarch64 then "linux-sbsa" else "linux-x86_64";
  installDriver = callPackage ../../cudaDriverSelector/install-driver.nix {
    inherit redistSystem;
    cudaDriverSelector = selector;
  };
  mock =
    runCommandCC "mock-cuda-drivers"
      {
        version = "620.70.06";
        outputs = [
          "out"
          "older"
        ];
      }
      ''
        mkdir -p "$out"/{compat,host,control} unknown/compat
        provider() {
          FIXTURE_ID="$1" NOTE_FORMAT="$2" DRIVER_BRANCHES="$3" ${shared} --cfg driver_note ${fixtures}/provider.rs \
            -Clink-arg=-Wl,-soname,libcuda.so.1 -o "$4"
        }
        provider 615 2 615 unknown/compat/libcuda.so.615.71.09
        ln -s libcuda.so.615.71.09 unknown/compat/libcuda.so.1
        cp -L unknown/compat/libcuda.so.1 "$out/host/"
        provider 620 1 615,620 "$out/compat/libcuda.so.620.70.06"
        ln -s libcuda.so.620.70.06 "$out/compat/libcuda.so.1"
        ln -s libcuda.so.1 "$out/host/libcuda.so"
        mkdir -p "$older/compat"
        provider 619 1 610,615 "$older/compat/libcuda.so.619.1"
        ln -s libcuda.so.619.1 "$older/compat/libcuda.so.1"
        companion=libnvidia-ptxjitcompiler.so
        FIXTURE_ID=620 ${shared} ${fixtures}/provider.rs -Clink-arg=-Wl,-soname,$companion.1 -o "$out/compat/$companion.620"
        ln -s "$companion.620" "$out/compat/$companion.1"
        FIXTURE_ID=615 ${shared} ${fixtures}/provider.rs -Clink-arg=-Wl,-soname,$companion.1 -o "$out/host/$companion.1"
        ${installDriver} "$out"
        ${installDriver} "$older"
        ${python.interpreter} -B ${../../cudaDriverSelector/elf}/manifest.py ${redistSystem} "$PWD/unknown"
        diff -u <(printf '615.71.9\n\n%s\n' "$PWD/unknown/compat/libcuda.so.615.71.09") \
          unknown/nix-support/nix-cuda-compat
        ${rustc} ${fixtures}/probe.rs -o "$out/control/probe"
        ${shared} --cfg by_name ${fixtures}/consumer.rs -o "$out/control/observer.so"
        name=''${out##*/}
        CUDA_STATIC_LOOKUP_SYMBOL="nix_cuda_dlopen_''${name%%-*}_archive" \
          ${shared} --cfg by_name --cfg static_lookup ${fixtures}/consumer.rs \
          -Clink-arg="$out/libexec/nix-cuda-static-lookup.o" -Clink-arg=-Wl,-z,defs -o "$out/control/static-runtime.so"
        mkdir -p "$out/control/extension"
        CUDA_BINDINGS_LOOKUP=__real_dlopen CUDA_BINDINGS_HOST_ANCHOR=absent-anchor.so \
          ${selector.compileObject} nix_cuda_bindings explicit_tail_calls,link_llvm_intrinsics \
          ${../../../../python-modules/cuda-bindings/driver-wrap.rs} -o bindings.o
        ${selector.compileObject} forward explicit_tail_calls ${fixtures}/forward.rs -o forward.o
        "$CC" -shared forward.o bindings.o -Wl,--wrap=dlopen,-z,defs -ldl -o "$out/control/extension/adapter.so"
        ${shared} --cfg by_name --cfg forwarded_lookup ${fixtures}/consumer.rs \
          -Clink-arg="$out/control/extension/adapter.so" '-Clink-arg=-Wl,-rpath,$ORIGIN/../host' -o "$out/control/requester.so"
        ${shared} --cfg retain_paths ${fixtures}/auditor.rs -o "$out/control/retaining-auditor.so"
        ${rustc} ${fixtures}/retained_path.rs -o "$out/control/retained-path"
        ${shared} ${fixtures}/auditor.rs -o "$out/control/existing-audit.so"
      '';
  hook =
    cuda_compat:
    autoAddCudaCompatRunpath.override {
      inherit cuda_compat;
      # These mock redistributables model a server toolkit even in an Orin package set.
      backendStdenv = {
        hostRedistSystem = redistSystem;
        cudaCapabilities = [ "9.0" ];
      };
      cudaDriverSelector = selector;
    };
  pythonAdapter = pythonDriverLookup.override { autoAddCudaCompatRunpath = hook mock; };
  runtime =
    major: candidate:
    stdenv.mkDerivation {
      name = "mock-cuda-runtime-${major}";
      phases = [
        "installPhase"
        "fixupPhase"
      ];
      nativeBuildInputs = [ (hook candidate) ];
      cudaCompatWrapDlopen = "${candidate}/nix-support/nix-cuda-compat";
      installPhase = ''
        mkdir -p "$out"/{lib,bin}
        # A runtime can supply policy even when another library opens the driver.
        ${shared} --cfg empty ${fixtures}/consumer.rs -Clink-arg=-Wl,-soname,libcudart.so.${major} -o "$out/lib/libcudart.so.${major}"
        ${shared} --cfg by_name ${fixtures}/consumer.rs -o "$out/lib/libclient-${major}.so"
        cp ${mock}/control/probe "$out/bin/consumer-${major}"
      '';
    };
  profile = buildEnv {
    name = "mock-cuda-driver-profile";
    paths = [
      (runtime "12" mock.older)
      (runtime "13" mock)
    ];
  };
in
stdenv.mkDerivation {
  name = "cuda-driver-selection-test";
  strictDeps = true;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  nativeBuildInputs = [
    (hook mock.older)
    (hook mock)
    buildPackages.binutils
  ];
  cudaCompatWrapDlopen = "${mock}/nix-support/nix-cuda-compat";
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"/{bin,linked,runtime/private}
    cp ${pythonAdapter} "$out/driver.py"
    ${rustc} --cfg executable ${fixtures}/consumer.rs -Clink-arg=${mock}/host/libcuda.so.1 \
      -Clink-arg=-Wl,--audit,${mock}/control/existing-audit.so -o "$out/bin/direct"
    ${shared} ${fixtures}/consumer.rs -Clink-arg=${mock}/host/libcuda.so.1 -o "$out/linked/plugin.so"
    ${shared} --cfg by_name ${fixtures}/consumer.rs '-Clink-arg=-Wl,-soname,libcudart.so.13,-rpath,$ORIGIN/private' \
      -o "$out/runtime/libcudart.so.13"
    FIXTURE_ID=7 ${shared} ${fixtures}/provider.rs -o "$out/runtime/private/libcaller-path.so"
    cp ${mock}/control/probe "$out/bin/late"
    runHook postInstall
  '';
  # Structural checks also run on foreign target binaries.
  postPhases = [ "checkDriverSelection" ];
  checkDriverSelection = ''
    # A downstream executable must still link after the runtime's import was renamed.
    ${rustc} --cfg downstream ${fixtures}/consumer.rs -Clink-arg=-fuse-ld=bfd -Clink-arg=-Wl,--no-allow-shlib-undefined \
      -Clink-arg="$out/runtime/libcudart.so.13" -o downstream
    audit=$(${stdenv.cc.targetPrefix}readelf -Wd "$out/bin/direct" | grep -E '\((AUDIT|DEPAUDIT)\)')
    grep -F '${mock}/control/existing-audit.so' <<< "$audit"
    grep -F '${selector}/lib/libnix-cuda-audit.so' <<< "$audit"
    helper=${mock}/libexec/libnix-cuda-driver-lookup.so
    search=$(${stdenv.cc.targetPrefix}readelf -Wd "$helper" | sed -nE 's/.*\((RPATH|RUNPATH)\).* \[(.*)\]$/\1 \2/p')
    [[ $search == "RPATH ${mock}/libexec/driver" ]]
    index="$out/nix-support/cuda-driver-selection"
    [[ -f "$index" && ! -L "$index" ]]
    expected=$(printf '%s\n' ${mock}/nix-support/nix-cuda-compat ${mock.older}/nix-support/nix-cuda-compat | sort)
    test "$(sort "$index")" = "$expected"
    for dir in "$out/bin" "$out/linked" "$out/runtime" "${profile}/bin" "${profile}/lib"; do
      test ! -e "$dir/nix-cuda-compat"
    done
    for major in 12 13; do
      executable=$(realpath "${profile}/bin/consumer-$major")
      test -s "''${executable%/bin/*}/nix-support/cuda-driver-selection"
    done
    ${lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      PYTHON=${buildPackages.python3.interpreter} bash ${./check.sh} "$out" "${mock}" "${selector}/lib/libnix-cuda-audit.so" "${profile}" \
        "${stdenv.cc.bintools.dynamicLinker}" ${if stdenv.hostPlatform.isAarch64 then "615" else "620"}
    ''}
  '';
  meta.platforms = [
    "aarch64-linux"
    "x86_64-linux"
  ];
}
