{
  cmake,
  fetchFromGitHub,
  fetchpatch,
  lib,
  llvm,
  lz4,
  nanothread,
  ninja,
  pkg-config,
  robin-map,
  stdenv,
  xxHash,
}:

stdenv.mkDerivation (
  finalAttrs: {
    pname = "drjit-core";
    version = "0-unstable-2023-12-05";
    
    strictDeps = true;
    __contentAddressed = true;

    # TODO: How do we avoid targeting the build platform?
    # drjit-core> -- Dr.Jit-Core: targeting the native CPU architecture (specify DRJIT_CORE_NATIVE_FLAGS to change this).
    src = fetchFromGitHub {
      owner = "mitsuba-renderer";
      repo = finalAttrs.pname;
      rev = "13e9d663dc0eab81dec23357c07157ebf2c07f1f";
      hash = "sha256-dxvnKym+m28Xyi/ye7f1bMhE+In5CSh49XnVX4imEtU=";
    };

    # Patches are cherry-picks from my feat/cmake-reusable-nanobind branch
    patches = [
      (fetchpatch {
        name = "cmake: make pre-built library discoverable via CMake configuration files";
        url = "https://github.com/mitsuba-renderer/drjit-core/pull/76/commits/903221213929b8a08bb12940d5ed6b456326612f.patch";
        hash = "sha256-OCFmwT/8+lfUN7Ca++6Yxot4J5BH7JJWrrjvhm5LAQE=";
      })
      (fetchpatch {
        name = "cmake: enable testing with CTests";
        url = "https://github.com/mitsuba-renderer/drjit-core/pull/76/commits/d1879c1cde8b32251e7daf9cefca225b9116f1e3.patch";
        hash = "sha256-ry5Gw2BiD2R2+GbsayPkrAi6ErOPe8KKAteyuguikws=";
      })
      (fetchpatch {
        name = "src/common.h: explicitly include cstdint";
        url = "https://github.com/mitsuba-renderer/drjit-core/pull/77/commits/585a01723e8e1eb0a3ae26840f4c32035dc6e86d.patch";
        hash = "sha256-GxR6tZZ1so+rzSWOkA6+Rd2zEv52txcPDfD6UnyqROc=";
      })
    ];

    # Copy the CMakeLists.txt some CMake defaults all these projects use
    # https://github.com/mitsuba-renderer/drjit-core/blob/13e9d663dc0eab81dec23357c07157ebf2c07f1f/CMakeLists.txt#L30
    prePatch = ''
      mkdir -p "./ext/nanothread/ext/cmake-defaults"
      cp "${nanothread.cmake-defaults}/CMakeLists.txt" "./ext/nanothread/ext/cmake-defaults/"
    '';

    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
    ];

    buildInputs = [
      llvm
      lz4
      nanothread
      robin-map
      xxHash
    ];

    cmakeFlags = [
      (lib.cmakeBool "DRJIT_ENABLE_TESTS" finalAttrs.doCheck)
      (lib.cmakeBool "DRJIT_DYNAMIC_LLVM" false)
      (lib.cmakeBool "DRJIT_USE_SYSTEM_NANOTHREAD" true)
      (lib.cmakeBool "DRJIT_USE_SYSTEM_LZ4" true)
      (lib.cmakeBool "DRJIT_USE_SYSTEM_ROBIN_MAP" true)
      (lib.cmakeBool "DRJIT_USE_SYSTEM_XXHASH" true)
    ];

    doCheck = true;

    # DrJit caches some files in the user's home directory, so we need to
    # override that to a temporary directory.
    # We also need to create $HOME/.drjit, otherwise when the tests run in parallel,
    # they will all try to create it at the same time and fail.
    preCheck = ''
      ORIG_HOME="$HOME"
      HOME="$(mktemp -d)"
      mkdir -p "$HOME/.drjit"
    '';

    # Clean up the temporary directory and restore the original home directory
    postCheck = ''
      rm -rf "$HOME"
      HOME="$ORIG_HOME"
      unset ORIG_HOME
    '';

    meta = with lib; {
      description = "Dr.Jit — A Just-In-Time-Compiler for Differentiable Rendering (core library";
      homepage = "https://github.com/mitsuba-renderer/drjit-core";
      license = licenses.bsd3;
      maintainers = with maintainers; [ connorbaker ];
      mainProgram = "drjit-core";
      platforms = platforms.all;
    };
  }
)
