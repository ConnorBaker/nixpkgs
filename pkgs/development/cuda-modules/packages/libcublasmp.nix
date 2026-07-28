{
  _cuda,
  buildRedist,
  libcublas,
  libnvshmem,
  nccl,
  tests,
}:
buildRedist {
  redistName = "cublasmp";
  pname = "libcublasmp";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
  ];

  # TODO: Looks like the minimum supported capability is 7.0 as of the latest:
  # https://docs.nvidia.com/cuda/cublasmp/getting_started/index.html
  buildInputs = [
    libcublas
    libnvshmem
    nccl
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libcuda.so.1"
  ];

  # Defined in `packages/tests/libcublasmp-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcublasmp-samples;

  meta = {
    description = "High-performance, multi-process, GPU-accelerated library for distributed basic dense linear algebra";
    longDescription = ''
      NVIDIA cuBLASMp is a high-performance, multi-process, GPU-accelerated library for distributed basic dense linear
      algebra.

      cuBLASMp is compatible with 2D block-cyclic data layout and provides PBLAS-like C APIs.
    '';
    homepage = "https://docs.nvidia.com/cuda/cublasmp";
    changelog = "https://docs.nvidia.com/cuda/cublasmp/release_notes";
    license = _cuda.lib.licenses.math_sdk_sla;
  };
}
