{
  buildRedist,
  cudaAtLeast,
  lib,
  libnvjitlink,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libcusparse";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  buildInputs =
    # Dependency from 12.0 and on
    lib.optionals (cudaAtLeast "12.0") [ libnvjitlink ];

  # Defined in `packages/tests/libcusparse-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcusparse-samples;

  meta = {
    description = "GPU-accelerated basic linear algebra subroutines for sparse matrix computations for unstructured sparsity";
    longDescription = ''
      The cuSPARSE APIs provides GPU-accelerated basic linear algebra subroutines for sparse matrix computations for
      unstructured sparsity.
    '';
    homepage = "https://developer.nvidia.com/cusparse";
    changelog = "https://docs.nvidia.com/cuda/cusparse";
  };
}
