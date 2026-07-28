{ buildRedist, tests }:
buildRedist {
  redistName = "nvjpeg2000";
  pname = "libnvjpeg_2k";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
  ];

  # Defined in `packages/tests/libnvjpeg_2k-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libnvjpeg_2k-samples;

  meta = {
    description = "Accelerates the decoding and encoding of JPEG2000 images on NVIDIA GPUs";
    longDescription = ''
      The nvJPEG2000 library accelerates the decoding and encoding of JPEG2000 images on NVIDIA GPUs.
    '';
    homepage = "https://docs.nvidia.com/cuda/nvjpeg2000";
    changelog = "https://docs.nvidia.com/cuda/nvjpeg2000/releasenotes.html";
  };
}
