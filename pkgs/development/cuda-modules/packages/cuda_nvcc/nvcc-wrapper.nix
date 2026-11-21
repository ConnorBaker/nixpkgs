{
  backendStdenv,
  callPackage,
  cudaAtLeast,
  lib,
}:
callPackage ../../wrapper/mk-tool-wrapper.nix { } {
  name = "nvcc-wrapper";
  source = ./nvcc-wrapper.cpp;
  description = "Wrapper for reproducible nvcc compilations";

  flags = [
    ''-DNVCC_BACKEND_BIN="${lib.makeBinPath [ backendStdenv.cc ]}"''
    "-DNVCC_HAS_RANDOM_SEED=${lib.boolToString (cudaAtLeast "12.9")}"
  ];
}
