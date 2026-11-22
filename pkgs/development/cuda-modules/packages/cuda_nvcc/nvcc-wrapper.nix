{
  backendStdenv,
  callPackage,
  cudaAtLeast,
  lib,
}:
callPackage ../../wrapper/mk-tool-wrapper.nix { } {
  name = "nvcc-wrapper";
  description = "Wrapper for reproducible nvcc compilations";

  env = {
    NVCC_BACKEND_BIN = lib.makeBinPath [ backendStdenv.cc ];
    NVCC_HAS_RANDOM_SEED = lib.boolToString (cudaAtLeast "12.9");
  };
}
