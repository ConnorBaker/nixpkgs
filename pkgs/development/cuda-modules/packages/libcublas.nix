{
  buildRedist,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libcublas";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  # Defined in `packages/tests/libcublas-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcublas-samples;

  meta = {
    description = "CUDA Basic Linear Algebra Subroutine library";
    longDescription = ''
      The cuBLAS library is an implementation of BLAS (Basic Linear Algebra Subprograms) on top of the NVIDIA CUDA runtime.
    '';
    homepage = "https://developer.nvidia.com/cublas";
  };
}
