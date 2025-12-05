{
  lib,
  stdenv,
  fetchFromGitHub,
  replaceVars,
  binutils,
  asciidoctor,
  cmake,
  perl,
  fmt,
  hiredis,
  xxHash,
  zstd,
  bashInteractive,
  doctest,
  xcodebuild,
  makeWrapper,
  ctestCheckHook,
  writableTmpDirAsHomeHook,
  nix-update-script,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "ccache";
  version = "4.12.2";

  src = fetchFromGitHub {
    owner = "ccache";
    repo = "ccache";
    tag = "v${finalAttrs.version}";
    # `git archive` replaces `$Format:%H %D$` in cmake/CcacheVersion.cmake
    # we need to replace it with something reproducible
    # see https://github.com/NixOS/nixpkgs/pull/316524
    postFetch = ''
      sed -i -E \
        's/version_info "([0-9a-f]{40}) .*(tag: v[^,]+).*"/version_info "\1 \2"/g w match' \
        $out/cmake/CcacheVersion.cmake
      if [ -s match ]; then
        rm match
      else # pattern didn't match
        exit 1
      fi
    '';
    hash = "sha256-oWzVCrNgYtOeN4+KJmIynT3jiFZfxrsLkoIm0lK3MBo=";
  };

  outputs = [
    "out"
    "man"
  ];

  patches = [
    # When building for Darwin, test/run uses dwarfdump, whereas on
    # Linux it uses objdump. We don't have dwarfdump packaged for
    # Darwin, so this patch updates the test to also use objdump on
    # Darwin.
    # Additionally, when cross compiling, the correct target prefix
    # needs to be set.
    (replaceVars ./fix-objdump-path.patch {
      objdump = "${binutils.bintools}/bin/${binutils.targetPrefix}objdump";
    })
  ];

  postPatch = ''
    patchShebangs --build test/fake-compilers
  '';

  strictDeps = true;

  nativeBuildInputs = [
    asciidoctor
    cmake
    perl
  ];

  buildInputs = [
    fmt
    hiredis
    xxHash
    zstd
  ];

  cmakeFlags = lib.optional (!finalAttrs.finalPackage.doCheck) "-DENABLE_TESTING=OFF";

  doCheck = true;

  nativeCheckInputs = [
    # test/run requires the compgen function which is available in
    # bashInteractive, but not bash.
    bashInteractive
    ctestCheckHook
    writableTmpDirAsHomeHook
  ]
  ++ lib.optional stdenv.hostPlatform.isDarwin xcodebuild;

  checkInputs = [
    doctest
  ];

  disabledTests = [
    "test.trim_dir" # flaky on hydra (possibly filesystem-specific?)
    "test.fileclone" # flaky on hydra, also seems to fail on zfs
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    "test.basedir"
    "test.multi_arch"
    "test.nocpp2"
  ];

  passthru = {
    # A derivation that provides gcc and g++ commands, but that
    # will end up calling ccache for the given cacheDir
    links =
      { unwrappedCC, extraConfig }:
      let
        isClang = unwrappedCC.isClang or false;
        isGNU = unwrappedCC.isGNU or false;
      in
      stdenv.mkDerivation {
        __structuredAttrs = true;
        strictDeps = true;

        pname = "ccache-links";
        inherit (finalAttrs) version;

        knownCompilers =
          let
            compilers = [
              "cc"
              "c++"
              "gcc"
              "g++"
              "clang"
              "clang++"
            ];

            # We always know what the target prefix is.
            # We wrap compilers with the target prefix optimistically.
            withTargetPrefix = map (
              compiler: "${unwrappedCC.stdenv.targetPlatform.config}-${compiler}"
            ) compilers;

            # Compilers sometimes have their version suffixed, e.g., gcc-14.3.0.
            withVersion = map (compiler: "${compiler}-${unwrappedCC.version}") compilers;

            # Compilers sometimes have both their target prefix and version suffixed, e.g.,
            # x86_64-unknown-linux-gnu-gcc-14.3.0.
            withTargetPrefixAndVersion = map (compiler: "${compiler}-${unwrappedCC.version}") withTargetPrefix;
          in
          compilers ++ withVersion ++ withTargetPrefix ++ withTargetPrefixAndVersion;

        compilerType =
          if isClang then
            "clang"
          else if isGNU then
            "gcc"
          else
            throw "unknown compiler type";

        lib = lib.getLib unwrappedCC;

        nativeBuildInputs = [ makeWrapper ];

        buildCommand = ''
          set -euo pipefail

          wrapWithCCache() {
            local -r compilerName=''${1:?}
            local -r compilerPath="${unwrappedCC}/bin/$compilerName"

            if [[ ! -x $compilerPath ]]; then
              nixDebugLog "Path $compilerPath does not exist or is not executable"
              return 0
            fi

            nixLog "removing symlink $out/bin/$compilerName"
            if [[ ! -L "$out/bin/$compilerName" ]]; then
              nixErrorLog "if $out/bin/$compilerName exists, it must be a symlink!"
              exit 1
            fi
            rm "$out/bin/$compilerName"

            # Use ccache's path argument to avoid cache-busting due to store path changes.
            makeWrapper "${lib.getExe finalAttrs.finalPackage}" "$out/bin/$compilerName" \
              --run ${lib.escapeShellArg extraConfig} \
              --add-flag "path=${unwrappedCC}/bin" \
              --add-flag "compiler_check=content" \
              --add-flag "compiler_type=$compilerType" \
              --add-flag "compiler=$compilerName" \
              --add-flag "$compilerName"
            nixLog "wrapped $compilerPath as $out/bin/$compilerName"
          }

          makeSymlinks() {
            mkdir -p "$out"

            nixLog "symlinking top-level files from ${unwrappedCC}"
            ln --symbolic --verbose "${unwrappedCC}"/* "$out/"

            nixLog "removing symlink: $out/bin"
            rm "$out/bin"

            nixLog "creating $out/bin"
            mkdir -p "$out/bin"

            nixLog "symlinking files from ${unwrappedCC}/bin"
            ln --symbolic --verbose "${unwrappedCC}/bin"/* "$out/bin/"
          }

          makeWrappers() {
            nixLog "wrapping binaries with ccache"
            for knownCompiler in "''${knownCompilers[@]}"; do
              wrapWithCCache "$knownCompiler"
            done
            unset -v knownCompiler
          }

          makeSymlinks
          makeWrappers
        '';

        passthru = {
          inherit isClang isGNU;
          isCcache = true;
        };

        meta = {
          inherit (unwrappedCC.meta) mainProgram;
        };
      };

    updateScript = nix-update-script { };
  };

  meta = with lib; {
    description = "Compiler cache for fast recompilation of C/C++ code";
    homepage = "https://ccache.dev";
    downloadPage = "https://ccache.dev/download.html";
    changelog = "https://ccache.dev/releasenotes.html#_ccache_${
      builtins.replaceStrings [ "." ] [ "_" ] finalAttrs.version
    }";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [
      kira-bruneau
      r-burns
    ];
    platforms = platforms.unix;
    mainProgram = "ccache";
  };
})
