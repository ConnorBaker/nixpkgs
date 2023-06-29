{
  cudaVersion,
  generateSplicesForMkScope,
  lib,
  makeScopeWithSplicing,
  pkgs,
}: let
  inherit (builtins) isList elem;
  inherit (lib.fixedPoints) composeManyExtensions extends;
  inherit (lib.strings) versionOlder;
  inherit (lib.trivial) const;
  inherit (lib.versions) major majorMinor;

  cudaPackagesFun = final: {
    # Here we put package set configuration and utility functions.
    inherit cudaVersion lib pkgs;
    cudaMajorVersion = major final.cudaVersion;
    cudaMajorMinorVersion = majorMinor final.cudaVersion;
    addBuildInputs = buildInputs: drv:
      drv.overrideAttrs (oldAttrs: {
        buildInputs = (oldAttrs.buildInputs or []) ++ buildInputs;
      });
    addAutoPatchelfIgnoreMissingDeps = deps: drv:
      drv.overrideAttrs (oldAttrs: {
        autoPatchelfIgnoreMissingDeps =
          if isList (oldAttrs.autoPatchelfIgnoreMissingDeps or [])
          then
            # We have a list!
            # Check if it contains the special "*" element
            if elem "*" (oldAttrs.autoPatchelfIgnoreMissingDeps or [])
            then
              # Case where it's already ignoring everything, leave it alone
              oldAttrs.autoPatchelfIgnoreMissingDeps
            else
              # Case where it's not ignoring everything or is unset and empty
              (oldAttrs.autoPatchelfIgnoreMissingDeps or []) ++ deps
          else
            # Case where we have a bool
            if oldAttrs.autoPatchelfIgnoreMissingDeps or false
            then
              # Case where we're already ignoring everything, leave it alone
              oldAttrs.autoPatchelfIgnoreMissingDeps
            else
              # Case where we're not ignoring everything
              deps;
      });
  };

  cutensorExtension = final: _: let
    inherit (final) cudaMajorMinorVersion cudaMajorVersion;

    buildCuTensorPackage = final.callPackage ../development/libraries/science/math/cutensor/generic.nix;

    cuTensorVersions = {
      "1.2.2.5".hash = "sha256-lU7iK4DWuC/U3s1Ct/rq2Gr3w4F2U7RYYgpmF05bibY=";
      "1.5.0.3".hash = "sha256-T96+lPC6OTOkIs/z3QWg73oYVSyidN0SVkBWmT9VRx0=";
    };

    cutensor = buildCuTensorPackage rec {
      version =
        if versionOlder cudaMajorMinorVersion "10.1"
        then "1.2.2.5"
        else "1.5.0.3";
      inherit (cuTensorVersions.${version}) hash;
      # This can go into generic.nix
      libPath = "lib/${
        if cudaMajorVersion == "10"
        then cudaMajorMinorVersion
        else cudaMajorVersion
      }";
    };
  in {inherit cutensor;};

  extraPackagesExtension = final: _: {
    nccl = final.callPackage ../development/libraries/science/math/nccl { };

    nccl-tests = final.callPackage ../development/libraries/science/math/nccl/tests.nix { };

    autoAddOpenGLRunpathHook = final.callPackage ( { makeSetupHook, addOpenGLRunpath }:
      makeSetupHook {
        name = "auto-add-opengl-runpath-hook";
        propagatedBuildInputs = [
          addOpenGLRunpath
        ];
      } ../development/compilers/cudatoolkit/auto-add-opengl-runpath-hook.sh
    ) {};
  };

  composedExtension = composeManyExtensions [
    extraPackagesExtension
    (import ../development/compilers/cudatoolkit/extension.nix)
    (import ../development/compilers/cudatoolkit/redist/extension.nix)
    (import ../development/compilers/cudatoolkit/redist/overrides.nix)
    (import ../development/libraries/science/math/cudnn/extension.nix)
    (import ../development/libraries/science/math/tensorrt/extension.nix)
    (import ../test/cuda/cuda-samples/extension.nix)
    (import ../test/cuda/cuda-library-samples/extension.nix)
    cutensorExtension
  ];

  cudaPackages =
    makeScopeWithSplicing
    (generateSplicesForMkScope "cudaPackages")
    (const {})
    (const {})
    (extends composedExtension cudaPackagesFun);
in
  cudaPackages
