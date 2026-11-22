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

  postInstall = lib.optionalString finalAttrs.finalPackage.meta.available (
    callPackage ../../wrapper/install-tool-wrappers.nix { } {
      wrappers.nvprune = finalAttrs.passthru.nvpruneWrapper;
    }
  );

  passthru.nvpruneWrapper = callPackage ../../wrapper/mk-tool-wrapper.nix { } {
    name = "nvprune-wrapper";
    source = ./nvprune-wrapper.cpp;
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
