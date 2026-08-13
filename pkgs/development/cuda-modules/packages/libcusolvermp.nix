{
  _cuda,
  buildRedist,
  cuda_cudart,
  libcublas,
  libcusolver,
  nccl,
  tests,
}:
buildRedist {
  redistName = "cusolvermp";
  pname = "libcusolvermp";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
  ];

  buildInputs = [
    cuda_cudart
    libcublas
    libcusolver
    nccl
  ];

  autoPatchelfIgnoreMissingDeps = [
    # Needs to be dynamically loaded as it depends on the hardware
    "libcuda.so.1"
  ];

  # Defined in `packages/tests/libcusolvermp-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcusolvermp-samples;

  meta = {
    description = "High-performance, distributed-memory, GPU-accelerated library that provides tools for solving dense linear systems and eigenvalue problems";
    longDescription = ''
      The NVIDIA cuSOLVERMp library is a high-performance, distributed-memory, GPU-accelerated library that provides
      tools for solving dense linear systems and eigenvalue problems.
    '';
    homepage = "https://developer.nvidia.com/cusolver";
  };
}
