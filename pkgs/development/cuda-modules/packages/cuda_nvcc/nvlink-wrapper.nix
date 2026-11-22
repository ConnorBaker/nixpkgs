{ callPackage }:
callPackage ../../wrapper/mk-tool-wrapper.nix { } {
  name = "nvlink-wrapper";
  source = ./nvlink-wrapper.cpp;
  description = "Wrapper for nvlink which removes references to the Nix store from its output";
}
