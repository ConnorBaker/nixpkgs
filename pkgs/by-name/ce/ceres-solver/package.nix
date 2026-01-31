{
  lib,
  stdenv,
  fetchFromGitHub,
  blas,
  cmake,
  eigen,
  gflags,
  glog,
  suitesparse,
  metis,
  runTests ? false,
  enableStatic ? stdenv.hostPlatform.isStatic,
  withBlas ? true,
}:

# gflags is required to run tests
assert runTests -> gflags != null;

stdenv.mkDerivation (finalAttrs: {
  pname = "ceres-solver";
  version = "2.2.0";

  src = fetchFromGitHub {
    owner = "ceres-solver";
    repo = finalAttrs.pname;
    tag = finalAttrs.version;
    hash = "sha256-5SdHXcgwTlkDIUuyOQgD8JlAElk7aEWcFo/nyeOgN/k=";
  };

  outputs = [
    "out"
    "dev"
  ];

  nativeBuildInputs = [ cmake ];
  buildInputs = lib.optional runTests gflags;
  propagatedBuildInputs = [
    eigen
    glog
  ]
  ++ lib.optionals withBlas [
    blas
    suitesparse
    metis
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_SHARED_LIBS" (!enableStatic))
  ];

  # The Basel BUILD file conflicts with the cmake build directory on
  # case-insensitive filesystems, eg. darwin.
  preConfigure = ''
    rm BUILD
  '';

  doCheck = runTests;

  checkTarget = "test";

  meta = {
    description = "C++ library for modeling and solving large, complicated optimization problems";
    license = lib.licenses.bsd3;
    homepage = "http://ceres-solver.org";
    maintainers = with lib.maintainers; [ giogadi ];
    platforms = lib.platforms.unix;
  };
})
