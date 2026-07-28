{
  buildRedist,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libnvjpeg";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  # Defined in `packages/tests/libnvjpeg-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libnvjpeg-samples;

  meta = {
    description = "Provides high-performance, GPU accelerated JPEG decoding functionality for image formats commonly used in deep learning and hyperscale multimedia applications";
    longDescription = ''
      The nvJPEG library provides high-performance, GPU accelerated JPEG decoding functionality for image formats
      commonly used in deep learning and hyperscale multimedia applications.
    '';
    homepage = "https://docs.nvidia.com/cuda/nvjpeg";
  };
}
