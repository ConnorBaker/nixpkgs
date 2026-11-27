{
  buildRedist,
  cudaToolWrapper,
  lib,
  runCommandCC,
  tool-wrapper,
}:
buildRedist (finalAttrs: {
  redistName = "cuda";
  pname = "cuda_nvprune";

  outputs = [ "out" ];

  postInstall = lib.optionalString finalAttrs.finalPackage.meta.available ''
    source ${tool-wrapper.installAdjacentWrapper}
    installAdjacentWrapper "''${!outputBin:?}/bin/nvprune" ${lib.getExe' cudaToolWrapper.nvprune "nvprune-wrapper"}
  '';

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
