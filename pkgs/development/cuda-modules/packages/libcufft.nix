{
  buildRedist,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libcufft";

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
