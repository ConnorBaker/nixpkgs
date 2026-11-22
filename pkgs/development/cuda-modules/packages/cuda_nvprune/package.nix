{
  buildRedist,
  callPackage,
  lib,
  runCommandCC,
}:
buildRedist (finalAttrs: {
  redistName = "cuda";
  pname = "cuda_nvprune";

  outputs = [ "out" ];

  postInstall = lib.optionalString finalAttrs.finalPackage.meta.available ''
    nixLog "wrapping nvprune to normalize archive member timestamps"
    mv --verbose "''${!outputBin:?}/bin/nvprune" "''${!outputBin:?}/bin/.nvprune-wrapped"
    install --mode=0755 "${finalAttrs.passthru.nvpruneWrapper}/bin/nvprune-wrapper" "''${!outputBin:?}/bin/nvprune"
  '';

  passthru.nvpruneWrapper = callPackage ../../wrapper/mk-tool-wrapper.nix { } {
    name = "nvprune-wrapper";
    description = "Wrapper for reproducible nvprune archives";
  };

  passthru.tests.reproducible = runCommandCC "nvprune-reproducible" {
    nativeBuildInputs = [ finalAttrs.finalPackage ];
  } "source ${./reproducible.sh}";

  meta = {
    description = "Prune host object files and libraries to only contain device code for the specified targets";
    longDescription = ''
      `nvprune` prunes host object files and libraries to only contain device code for the specified targets.
    '';
    homepage = "https://docs.nvidia.com/cuda/cuda-binary-utilities#nvprune";
  };
})
