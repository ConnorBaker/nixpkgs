{
  buildPackages,
  lib,
  patchelf,
  rustPlatform,
  stdenv,
  hostRoot ? "",
}:

let
  hostDirs = import ./host-directories.nix { inherit lib stdenv; };
  libc = stdenv.cc.libc;
  lastDefault = if libc.libgcc or null != null then libc.libgcc else lib.getLib libc;
  target = stdenv.hostPlatform.rust.rustcTarget;
  # rustc needs an explicit flag to honor stdenv's native stack protector.
  stackProtector = ''
    rustHardening=()
    if [[ " ''${NIX_HARDENING_ENABLE:-} " == *" stackprotector "* ]]; then
      rustHardening+=(-Zstack-protector=strong)
    fi
  '';
in
rustPlatform.buildRustPackage {
  pname = "nix-cuda-driver-selector";
  version = "1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ patchelf ];
  outputs = [
    "out"
    "dev"
  ];
  env = {
    NIX_CUDA_STORE_DIR = builtins.storeDir;
    NIX_CUDA_HOST_ROOT = hostRoot;
    NIX_CUDA_HOST_DIRS = lib.concatStringsSep "\n" hostDirs;
    NIX_CUDA_LAST_DEFAULT = "${lastDefault}/lib";
  };

  buildPhase = ''
    runHook preBuild
    ${stackProtector}
    RUSTC_BOOTSTRAP=nix_cuda_policy cargo rustc --offline --release --target ${target} -- \
      -Zallow-features= "''${rustHardening[@]}"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 target/${target}/release/libnix_cuda_policy.a "$dev/lib/libnix_cuda_policy.a"

    # glibc uses the active loader's libc in the audit namespace. Publish only
    # the audit ABI and bind all its imports before early startup callbacks.
    mkdir -p "$out/lib"
    echo '{ global: la_version; la_objopen; la_objclose; la_objsearch; local: *; };' > exports
    NIX_DONT_SET_RPATH=1 $CC -shared -Wl,-z,now,-z,defs,--gc-sections,--version-script=exports \
      -Wl,-u,la_version,-u,la_objopen,-u,la_objclose,-u,la_objsearch "$dev/lib/libnix_cuda_policy.a" \
      -o "$out/lib/libnix-cuda-audit.so"
    runHook postInstall
  '';

  # An LD_AUDIT object must resolve libc from the invoking loader even when
  # Nix's normal ELF fixup leaves an empty RUNPATH tag.
  postFixup = ''
    patchelf --remove-rpath "$out/lib/libnix-cuda-audit.so"
  '';

  # Compile the no_std leaf objects for the consumer's CPU, including cross builds.
  passthru.compileObject = buildPackages.writeShellScript "compile-cuda-lookup" ''
    set -eu
    export RUSTC_BOOTSTRAP="$1"
    features=$2
    shift 2
    ${stackProtector}
    exec ${buildPackages.rustc}/bin/rustc --edition=2024 --crate-name="$RUSTC_BOOTSTRAP" \
      --crate-type=lib --emit=obj --target=${stdenv.hostPlatform.rust.rustcTargetSpec} \
      -Crelocation-model=pic -Copt-level=2 -Cpanic=abort -Zallow-features="$features" "''${rustHardening[@]}" "$@"
  '';

  meta = {
    description = "Select the CUDA user-space driver library during glibc lookup";
    license = lib.licenses.mit;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    teams = [ lib.teams.cuda ];
  };
}
