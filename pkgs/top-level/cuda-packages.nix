{
  _cuda,
  callPackage,
  config,
  lib,
  pkgs,
  stdenv,
}:
let
  # NOTE: Because manifests are used to add redistributables to the package set,
  # we cannot have values depend on the package set itself, or we run into infinite recursion.

  # Since Jetson capabilities are never built by default, we can check if any of them were requested
  # through final.config.cudaCapabilities and use that to determine if we should change some manifest versions.
  # Copied from backendStdenv.
  hasJetsonCudaCapability =
    let
      jetsonCudaCapabilities = lib.filter (
        cudaCapability: _cuda.db.cudaCapabilityToInfo.${cudaCapability}.isJetson
      ) _cuda.db.allSortedCudaCapabilities;
    in
    lib.intersectLists jetsonCudaCapabilities (config.cudaCapabilities or [ ]) != [ ];
  selectManifests = lib.mapAttrs (name: version: _cuda.manifests.${name}.${version});
in
{
  cudaPackages_12_6 = callPackage ../development/cuda-modules {
    manifests = selectManifests {
      cuda = "12.6.3";
      cudnn = "9.8.0";
      cusparselt = "0.6.3";
      cutensor = "2.2.0";
      tensorrt = if hasJetsonCudaCapability then "10.7.0" else "10.9.0";
    };
  };

  cudaPackages_12_8 = callPackage ../development/cuda-modules {
    manifests = selectManifests {
      cuda = "12.8.1";
      cudnn = "9.8.0";
      cusparselt = "0.7.1";
      cutensor = "2.2.0";
      tensorrt = if hasJetsonCudaCapability then "10.7.0" else "10.9.0";
    };
  };

  cudaPackages_12_9 = callPackage ../development/cuda-modules {
    manifests = selectManifests {
      cuda = "12.9.1";
      cudnn = "9.8.0";
      cusparselt = "0.7.1";
      cutensor = "2.2.0";
      tensorrt = if hasJetsonCudaCapability then "10.7.0" else "10.9.0";
    };
  };
}
