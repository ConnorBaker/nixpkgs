{
  buildRedist,
  cuda_nvrtc,
  cudaAtLeast,
  lib,
  libnvjitlink,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libcufft";

  # dlopen'd for LTO callbacks (cufftXtSetJITCallback, CUFFT_FORCE_LTO). Gated because libnvjitlink
  # does not exist before CUDA 12.0, and 11.x libcufft references neither soname.
  appendRunpaths = lib.optionals (cudaAtLeast "12.0") (
    map (pkg: "${lib.getLib pkg}/lib") [
      cuda_nvrtc # libnvrtc.so.%s
      libnvjitlink # libnvJitLink.so.%s
    ]
  );

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  # Defined in `packages/tests/libcufft-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libcufft-samples;

  meta = {
    description = "High-performance FFT product CUDA library";
    homepage = "https://developer.nvidia.com/cufft";
  };
}
