{ lib }:
lib.fixedPoints.makeExtensible (final: {
  utils = import ./utils.nix {
    inherit lib;
    cudaLib = final;
  };
})
