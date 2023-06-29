# TO USE:
# nix build --keep-going --impure -L --expr "$(cat ./test-build-all-cuda-package-sets.nix)"
let
  # importNixpkgs : AttrSet -> AttrSet
  inherit (builtins) elem getAttr import;
  importNixpkgs = import ../../../../..;
  inherit (importNixpkgs {}) lib;
  inherit
    (lib.attrsets)
    attrByPath
    filterAttrs
    genAttrs
    mapAttrs'
    nameValuePair
    optionalAttrs
    recurseIntoAttrs
    ;
  inherit (lib.trivial) flip pipe;
  inherit (lib.lists) all map;
  inherit (lib.strings) hasPrefix replaceStrings;

  # Each supported system config has multiple versions of CUDA.
  # Map the arch name the redistributables used to the config name we'd need to use to
  # cross-compile. Additionally, include cudaCapabilities we want to use instead of the default.
  redistArchToSystemConfig = {
    # redist arch: linux-sbsa, no Jetson devices by default
    # linux-sbsa.crossSystem.config = "aarch64-unknown-linux-gnu";
    # # redist arch:  (Linux4Tegra), specifying Jetson devices
    # linux-aarch64 = {
    #   crossSystem.config = "aarch64-unknown-linux-gnu";
    #   # 7.2 is the first Jetson device supported by 11.4+
    #   # 8.7 has support from 11.5 onwards, but we still need to support 11.4.
    #   cudaCapabilities = ["7.2"];
    # };
    # redist arch: linux-ppc64le
    linux-ppc64le.crossSystem.config = "powerpc64le-unknown-linux-gnu";
    # redist arch: linux-x86_64
    # linux-x86_64.crossSystem.config = "x86_64-unknown-linux-gnu";
    # redist arch: windows-x86_64 (troublemaker; ignored for now)
  };

  # Each version of CUDA supports multiple compute capabilities
  cudaVersions = [
    # "11.4"
    "11.5"
    # "11.6"
    # "11.7"
    # "11.8"
    # "12.0"
    # "12.1"
  ];

  cudaPackageSetNames =
    map (version: "cudaPackages_${replaceStrings ["."] ["_"] version}") cudaVersions;

  setupNixpkgs = {
    crossSystem,
    cudaCapabilities ? null,
  }:
    importNixpkgs {
      inherit crossSystem;
      config =
        {
          # Mind you, we don't actually build things that are broken or unsupported.
          # However, we do need to be able to *evaluate* them.
          allowBroken = true;
          allowUnfree = true;
          allowUnsupportedSystem = true;
          cudaSupport = true;
        }
        # Only include cudaCapabilities when non-null
        // optionalAttrs (cudaCapabilities != null) {inherit cudaCapabilities;};
    };

  ignoredPackagePrefixes = ["tensorrt"];
  packagePredicates = {
    nameIsOkay = name: all (ignoredPrefix: !(hasPrefix ignoredPrefix name)) ignoredPackagePrefixes;
    isBroken = value: attrByPath ["meta" "broken"] false value;
    platformIsSupported = nixpkgs: value: let
      platforms = attrByPath ["meta" "platforms"] [] value;
    in
      platforms == [] || elem nixpkgs.stdenv.hostPlatform.system platforms;
  };

  packageAttrsFilter = nixpkgs: name: value:
    with packagePredicates;
      nameIsOkay name
      && !(isBroken value)
      && platformIsSupported nixpkgs value;

  # Extract all the cuda package sets from an instance of nixpkgs
  extractCudaPackageSets = nixpkgs:
    genAttrs cudaPackageSetNames (flip pipe [
      (flip getAttr nixpkgs)
      (filterAttrs (packageAttrsFilter nixpkgs))
      # Ensure buildable
      recurseIntoAttrs
    ]);

  # Setup, extract, and make cuda package sets buildable
  wrapper = flip pipe [
    setupNixpkgs
    extractCudaPackageSets
    recurseIntoAttrs
  ];

  cudaPackageSets =
    mapAttrs' (name: value: nameValuePair name (wrapper value)) redistArchToSystemConfig;
in
  cudaPackageSets
