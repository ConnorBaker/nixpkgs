{ _cuda, lib }:
{
  /**
    Returns whether a capability should be built by default for a particular CUDA version.

    Capabilities built by default are baseline, non-Jetson capabilities with relatively recent CUDA support.

    NOTE: No guarantees are made about this function's stability. You may use it at your own risk.

    # Type

    ```
    _cudaCapabilityIsDefault
      :: (cudaMajorMinorVersion :: Version)
      -> (cudaCapabilityInfo :: CudaCapabilityInfo)
      -> Bool
    ```

    # Inputs

    `cudaMajorMinorVersion`

    : The CUDA version to check

    `cudaCapabilityInfo`

    : The capability information to check
  */
  _cudaCapabilityIsDefault =
    cudaMajorMinorVersion: cudaCapabilityInfo:
    let
      recentCapability =
        cudaCapabilityInfo.dontDefaultAfterCudaMajorMinorVersion == null
        || lib.versionAtLeast cudaCapabilityInfo.dontDefaultAfterCudaMajorMinorVersion cudaMajorMinorVersion;
    in
    recentCapability
    && !cudaCapabilityInfo.isJetson
    && !cudaCapabilityInfo.isArchitectureSpecific
    && !cudaCapabilityInfo.isFamilySpecific;

  /**
    Returns whether a capability is supported for a particular CUDA version.

    NOTE: No guarantees are made about this function's stability. You may use it at your own risk.

    # Type

    ```
    _cudaCapabilityIsSupported
      :: (cudaMajorMinorVersion :: Version)
      -> (cudaCapabilityInfo :: CudaCapabilityInfo)
      -> Bool
    ```

    # Inputs

    `cudaMajorMinorVersion`

    : The CUDA version to check

    `cudaCapabilityInfo`

    : The capability information to check
  */
  _cudaCapabilityIsSupported =
    cudaMajorMinorVersion: cudaCapabilityInfo:
    let
      lowerBoundSatisfied = lib.versionAtLeast cudaMajorMinorVersion cudaCapabilityInfo.minCudaMajorMinorVersion;
      upperBoundSatisfied =
        cudaCapabilityInfo.maxCudaMajorMinorVersion == null
        || lib.versionAtLeast cudaCapabilityInfo.maxCudaMajorMinorVersion cudaMajorMinorVersion;
    in
    lowerBoundSatisfied && upperBoundSatisfied;

  /**
    Generates a CUDA variant name from a version.

    NOTE: No guarantees are made about this function's stability. You may use it at your own risk.

    # Type

    ```
    _mkCudaVariant :: (version :: String) -> String
    ```

    # Inputs

    `version`

    : The version string

    # Examples

    :::{.example}
    ## `_cuda.lib._mkCudaVariant` usage examples

    ```nix
    _mkCudaVariant "11.0"
    => "cuda11"
    ```
    :::
  */
  _mkCudaVariant = version: "cuda${lib.versions.major version}";

  /**
    A predicate which, given a package, returns true if the package has a free license or one of NVIDIA's licenses.

    This function is intended to be provided as `config.allowUnfreePredicate` when `import`-ing Nixpkgs.

    # Type

    ```
    allowUnfreeCudaPredicate :: (package :: Package) -> Bool
    ```
  */
  allowUnfreeCudaPredicate =
    let
      cudaLicenses = [
        lib.licenses.nvidiaCuda
        lib.licenses.nvidiaCudaRedist
      ]
      ++ lib.attrValues _cuda.lib.licenses;
      cudaLicenseNames = lib.map (license: license.shortName) cudaLicenses;
    in
    package:
    # new compound licenses
    if lib.isAttrs package.meta.license && lib.hasAttr "licenseType" package.meta.license then
      lib.licenses.evaluateProperty (
        license: (license.free or false) || lib.elem license cudaLicenses
      ) true (package.meta.license or [ ])
    else
      # old license list
      lib.all (
        license: (license.free or false) || lib.elem (license.shortName or null) cudaLicenseNames
      ) (lib.toList package.meta.license);

  /**
    System features for scheduling tests against the physical GPUs' compute capabilities.

    Baseline requirements use minimum-version ordering; architecture-specific requirements
    need the exact base capability, and family-specific requirements need the same major
    version and a sufficient minor. Multiple GPUs advertise the union, since their
    architecture-specific features are not interchangeable.

    This is a scheduling relation, not a guarantee of binary compatibility. The package
    set must compile for the execution hardware. Inputs must name known physical GPU
    capabilities, not suffixed compilation targets.

    # Type

    ```
    getCudaSystemFeatures :: [CudaCapability] -> [String]
    ```

    # Examples

    ```nix
    nix.settings.system-features =
      [ "big-parallel" "cuda" ] ++ pkgs._cuda.lib.getCudaSystemFeatures [ "8.9" ];
    ```
  */
  getCudaSystemFeatures =
    cudaCapabilities:
    let
      infoOf = cudaCapability: _cuda.db.cudaCapabilityToInfo.${cudaCapability};

      isFeatureSet =
        cudaCapability:
        (infoOf cudaCapability).isArchitectureSpecific || (infoOf cudaCapability).isFamilySpecific;

      # The GPU a feature set is spoken of relative to: "9.0a" and "9.0f" are both "9.0".
      baseOf =
        cudaCapability: lib.head (lib.match "([[:digit:]]+\\.[[:digit:]]+)[[:lower:]]+" cudaCapability);

      satisfies =
        cudaCapability: required:
        let
          info = infoOf required;
        in
        if info.isArchitectureSpecific then
          baseOf required == cudaCapability
        else if info.isFamilySpecific then
          lib.versions.major required == lib.versions.major cudaCapability
          && lib.versionAtLeast cudaCapability (baseOf required)
        else
          lib.versionAtLeast cudaCapability required;

      featuresFor =
        cudaCapability:
        assert lib.asserts.assertMsg (
          _cuda.db.cudaCapabilityToInfo ? ${cudaCapability}
        ) "_cuda.lib.getCudaSystemFeatures: unknown CUDA capability ${cudaCapability}";
        assert lib.asserts.assertMsg (!isFeatureSet cudaCapability)
          "_cuda.lib.getCudaSystemFeatures: ${cudaCapability} is a feature set rather than a GPU; pass ${baseOf cudaCapability}";
        lib.map _cuda.lib.mkCudaSystemFeature (
          lib.filter (satisfies cudaCapability) _cuda.db.allSortedCudaCapabilities
        );
    in
    lib.unique (lib.concatMap featuresFor cudaCapabilities);

  /**
    The exact-match feature name shared by test requirements and builder advertisements.

    # Type

    ```
    mkCudaSystemFeature :: CudaCapability -> String
    ```

    # Examples

    ```nix
    mkCudaSystemFeature "8.9"
    => "cuda-sm-89"
    ```
  */
  mkCudaSystemFeature = cudaCapability: "cuda-sm-${_cuda.lib.dropDots cudaCapability}";
}
