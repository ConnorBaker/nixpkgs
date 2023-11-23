{
  buildPythonPackage,
  cmake,
  drjit-core,
  fetchFromGitHub,
  lib,
  nanobind,
  ninja,
  nanothread,
  pathspec,
  pybind11,
  pkg-config,
  pkgs,
  pyproject-metadata,
  pytestCheckHook,
  robin-map,
  scikit-build-core,
  scikit-build,
  stdenv,
  xxHash,
}:

buildPythonPackage {
  pname = "drjit";
  version = "0-unstable-2024-01-15";
  pyproject = true;

  # NOTE: __structuredAttrs breaks the pytest and import check hooks.
  __contentAddressed = true;

  src = fetchFromGitHub {
    owner = "mitsuba-renderer";
    repo = "drjit";
    rev = "8f0976008f3662756bb078f713e383a98f944e1d";
    hash = "sha256-1s+epSiwfTvljDRe0Ks/59GcfuOhCorCLbmaYTWUDbU=";
  };

  # patches = [
  #   ./0001-cmake-try-find_package-drjit-core-first.patch
  #   ./0002-autodiff-link-tsl-xxhash-lz4-directly.patch
  #   ./0003-cmake-export-the-drjit-python-target-too.patch
  #   ./0004-cmake-dont-override-install-directories-on-nix.patch
  # ];

  prePatch =
    # Copy the CMakeLists.txt some CMake defaults all these projects use
    # https://github.com/mitsuba-renderer/drjit/blob/8f0976008f3662756bb078f713e383a98f944e1d/CMakeLists.txt#L20
    ''
      mkdir -p "./ext/drjit-core/ext/nanothread/ext/cmake-defaults"
      cp "${nanothread.cmake-defaults}/CMakeLists.txt" "./ext/drjit-core/ext/nanothread/ext/cmake-defaults/"
    '';
  # Remove the explicit nanobind GitHub dependency
  # + ''
  #   substituteInPlace "pyproject.toml" \
  #     --replace \
  #       '"nanobind @ git+https://github.com/wjakob/nanobind@master"]' \
  #       '"nanobind"]'
  # '';

  # resources/generate_stub_files.py attempts writing to ~/.drjit at build
  # time; generate_stub_files is also the reason that cross-compilation is
  # kind of broken upstream
  preConfigure = ''
    ORIG_HOME="$HOME"
    HOME="$(mktemp -d)"
    mkdir -p "$HOME/.drjit"
  '';

  dontUseCmakeConfigure = true;

  nativeBuildInputs = [
    cmake
    ninja
    # pkg-config
    # pybind11
    scikit-build
  ];

  buildInputs = [
    drjit-core
    pybind11
    nanobind
    # pathspec
    # pkgs.lz4
    # pyproject-metadata
    # robin-map
    # scikit-build-core
    # xxHash
    # stdenv.cc.cc.lib # libatomic, although they do not actually use it
  ];

  # Now that scikit-build is done installing its useless cmake targets into the
  # wheel (transitively, site-packages), we reconfigure and install into $out.
  cmakeFlags = [
    (lib.cmakeBool "CLEANUP_AFTER_SKBUILD" true)
    (lib.cmakeFeature "CMAKE_INSTALL_PREFIX" "${placeholder "out"}")
    (lib.cmakeFeature "CMAKE_INSTALL_LIBDIR" "${placeholder "out"}/lib")
    (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "${placeholder "out"}/include")
    (lib.cmakeFeature "CMAKE_INSTALL_DATAROOTDIR" "${placeholder "out"}/share")
  ];

  postInstall =
    ''
      for skBuildDir in _skbuild/* ; do
          cmake -S . -B "$skBuildDir/cmake-build" $cmakeFlags "''${cmakeFlagsArray[@]}"
          cmake --build "$skBuildDir/cmake-build"
          cmake --install "$skBuildDir/cmake-build"
      done
    ''
    # Clean up the temporary directory and restore the original home directory
    + ''
      rm -rf "$HOME"
      HOME="$ORIG_HOME"
      unset ORIG_HOME
    '';

  nativeCheckInputs = [ pytestCheckHook ];

  # Ensure drjit.drjit_ext is imported from $out/${python.sitePackages} and not CWD:
  preCheck = ''
    cd tests
  '';

  pythonImportsCheck = [
    "drjit"
    "drjit.drjit_ext"
  ];

  meta = with lib; {
    description = "Dr.Jit — A Just-In-Time-Compiler for Differentiable Rendering";
    homepage = "https://github.com/mitsuba-renderer/drjit";
    license = licenses.bsd3;
    maintainers = with maintainers; [ connorbaker ];
  };
}
