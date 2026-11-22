{
  callPackage,
  cudaOlder,
  lib,
}:
callPackage ../../wrapper/mk-tool-wrapper.nix { } {
  name = "ptxas-wrapper";
  description = "Wrapper for reproducible ptxas line information";
  env.PTXAS_INHERITS_MTIME = lib.boolToString (cudaOlder "13.4");
}
