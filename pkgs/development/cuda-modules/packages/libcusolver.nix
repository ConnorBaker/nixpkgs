{
  buildRedist,
  cudaAtLeast,
  lib,
  libcublas,
  libcusparse,
  libnvjitlink,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libcusolver";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  buildInputs =
    # Always depends on this
    [ (lib.getLib libcublas) ]
    # Dependency from 12.0 and on
    ++ lib.optionals (cudaAtLeast "12.0") [ libnvjitlink ]
    # Dependency from 12.1 and on
    ++ lib.optionals (cudaAtLeast "12.1") [ (lib.getLib libcusparse) ];

  # Defined in `packages/tests/libcusolver-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcusolver-samples;

  meta = {
    description = "Collection of dense and sparse direct linear solvers and Eigen solvers";
    longDescription = ''
      The NVIDIA cuSOLVER library provides a collection of dense and sparse direct linear solvers and Eigen solvers
      which deliver significant acceleration for Computer Vision, CFD, Computational Chemistry, and Linear
      Optimization applications.
    '';
    homepage = "https://developer.nvidia.com/cusolver";
  };
}
