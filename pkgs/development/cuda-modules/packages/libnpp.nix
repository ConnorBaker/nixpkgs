{
  buildRedist,
  tests,
}:
buildRedist {
  redistName = "cuda";
  pname = "libnpp";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
    "stubs"
  ];

  # Defined in `packages/tests/libnpp-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libnpp-samples;

  meta = {
    description = "Library of primitives for image and signal processing";
    longDescription = ''
      NPP is a library of over 5,000 primitives for image and signal processing that lets you easily perform tasks
      such as color conversion, image compression, filtering, thresholding, and image manipulation.
    '';
    homepage = "https://developer.nvidia.com/npp";
  };
}
