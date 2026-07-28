{ buildRedist, tests }:
buildRedist {
  redistName = "nppplus";
  pname = "libnpp_plus";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  # Defined in `packages/tests/libnpp_plus-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libnpp_plus-samples;

  meta = {
    description = "C++ support for interfacing with the NVIDIA Performance Primitives (NPP) library";
    longDescription = ''
      NPP is a library of over 5,000 primitives for image and signal processing that lets you easily perform tasks
      such as color conversion, image compression, filtering, thresholding, and image manipulation.
    '';
    homepage = "https://developer.nvidia.com/npp";
    changelog = "https://docs.nvidia.com/cuda/nppplus/releasenotes";
  };
}
