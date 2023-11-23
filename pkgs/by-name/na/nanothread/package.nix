{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchpatch,
  cmake,
  ninja,
}:

let
  cmake-defaults-unstable-2024-01-18 = fetchFromGitHub {
    owner = "mitsuba-renderer";
    repo = "cmake-defaults";
    rev = "24099f691d55b528e271c30e6733109532fb3b6b";
    hash = "sha256-KOgo7P1lZm7YlKMK3xyXKdusbxITa1rrjlFf3huZkPo=";
  };
in

stdenv.mkDerivation (
  finalAttrs: {
    pname = "nanothread";
    version = "0-unstable-2023-12-05";

    strictDeps = true;
    __contentAddressed = true;

    src = fetchFromGitHub {
      owner = "mitsuba-renderer";
      repo = finalAttrs.pname;
      rev = "dfd55bff74e12ebdaaf4540ff97730bdf08fa6c1";
      hash = "sha256-sPSqE3lqmv2gP6pPsnE0sW673Rdfd+TnucNFuJUyhD0=";
    };

    patches = [
      (fetchpatch {
        name = "cmake: make pre-built library discoverable via CMake configuration files";
        url = "https://github.com/mitsuba-renderer/nanothread/pull/7/commits/d6e0cf9f7e2a0e5a9e58728e568bcee9bcfff02d.patch";
        hash = "sha256-34WPa55tLHaBmCM4eC1UtTu88IJW6AMl0K2jVohGuaM=";
      })
      (fetchpatch {
        name = "cmake: enable testing with CTests";
        url = "https://github.com/mitsuba-renderer/nanothread/pull/7/commits/dd0259f07342cac8fb7407a5d1791d045dd5319d.patch";
        hash = "sha256-JznX850fVRPFACJCW+4BWCtd2KqU2InDr4GaUwr9cNw=";
      })
    ];

    # Copy the CMakeLists.txt some CMake defaults all these projects use
    # https://github.com/mitsuba-renderer/nanothread/blob/dfd55bff74e12ebdaaf4540ff97730bdf08fa6c1/CMakeLists.txt#L23
    prePatch = ''
      mkdir -p "./ext/cmake-defaults"
      cp "${cmake-defaults-unstable-2024-01-18}/CMakeLists.txt" "./ext/cmake-defaults/"
    '';

    nativeBuildInputs = [
      cmake-defaults-unstable-2024-01-18
      cmake
      ninja
    ];

    buildInputs = [
      stdenv.cc.cc.lib # libatomic
    ];

    cmakeFlags = [ (lib.cmakeBool "NANOTHREAD_ENABLE_TESTS" (finalAttrs.doCheck)) ];

    doCheck = true;

    passthru.cmake-defaults = cmake-defaults-unstable-2024-01-18;

    meta = with lib; {
      description = "Nanothread — Minimal thread pool for task parallelism";
      homepage = "https://github.com/mitsuba-renderer/nanothread";
      license = licenses.bsd3;
      maintainers = with maintainers; [ connorbaker ];
      mainProgram = "nanothread";
      platforms = platforms.all;
    };
  }
)
