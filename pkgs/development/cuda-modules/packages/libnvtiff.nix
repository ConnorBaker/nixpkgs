{ buildRedist, tests }:
buildRedist {
  redistName = "nvtiff";
  pname = "libnvtiff";

  outputs = [
    "out"
    "dev"
    "include"
    "lib"
    "static"
  ];

  # Defined in `packages/tests/libnvtiff-samples`, not here: a redistributable is unpacked rather
  # than compiled, so nothing which exercises it is part of building it.
  passthru.tests = tests.libnvtiff-samples;

  meta = {
    description = "Accelerates TIFF encode/decode on NVIDIA GPUs";
    longDescription = ''
      nvTIFF is a GPU accelerated TIFF(Tagged Image File Format) encode/decode library built on the CUDA platform.
    '';
    homepage = "https://docs.nvidia.com/cuda/nvtiff";
    changelog = "https://docs.nvidia.com/cuda/nvtiff/releasenotes.html";
  };
}
