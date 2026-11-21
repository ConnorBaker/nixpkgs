{ callPackage, cudaOlder }:
callPackage ../../wrapper/mk-tool-wrapper.nix { } {
  name = "ptxas-wrapper";
  source = ./ptxas-wrapper.cpp;
  description = "Wrapper for reproducible ptxas line information";
  flags = [
    "-DPTXAS_INHERITS_MTIME=${if cudaOlder "13.4" then "true" else "false"}"
  ];
}
