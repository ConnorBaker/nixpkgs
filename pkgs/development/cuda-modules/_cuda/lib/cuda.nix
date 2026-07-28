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
      cudaLicenseNames = [
        lib.licenses.nvidiaCuda.shortName
      ]
      ++ lib.map (license: license.shortName) (lib.attrValues _cuda.lib.licenses);
    in
    package:
    lib.all (license: license.free || lib.elem (license.shortName or null) cudaLicenseNames) (
      lib.toList package.meta.license
    );

  /**
    The Nix system features a builder should advertise, given the CUDA capabilities of its GPUs.

    Nix matches `requiredSystemFeatures` by exact string, so a *minimum* capability cannot be
    expressed by a requirement: a builder advertises every capability it is able to run instead, and
    a derivation requires the single feature naming its minimum. An RTX 4090 (8.9) advertises
    everything up to and including 8.9 and is therefore chosen for a test needing 8.9 but not for one
    needing 10.0, while an A100 (8.0) is chosen for neither.

    This is the closure `cudaPackages.tests` is scheduled by; see `packages/tests/support/mkTest.nix`.

    ## The three flavours

    A compute capability X.Y names three compilation targets, which differ in the instructions the
    compiler will emit and, separately, in where the result runs:

    - `sm_XY`, baseline: the portable instructions only.
    - `sm_XYf`, family-specific: baseline plus the accelerated instructions which the whole family
      implements. A *family* is a major compute capability version, so 10.0, 10.1 and 10.3 are one
      family and 12.0 and 12.1 are another. `sm_XY` and `sm_XYf` produce the same cubin and run in
      the same places; the suffix widens what may be written, not where it goes.
    - `sm_XYa`, architecture-specific: everything, including instructions NVIDIA guarantees nothing
      about beyond this one capability. It runs on X.Y and on nothing else -- not on X.Z for a later
      Z, which is the case `f` exists to serve.

    So a GPU at X.Y runs `sm_XZa` only for Z == Y, and `sm_XZf` for every Z <= Y in the same major X.
    Both of those are exact-membership questions rather than points on a version axis, which is why
    ordering by version gets each of them wrong in a different direction: `"12.1a"` sorts above
    `"12.1"`, so a version closure would admit `sm_90a` -- which runs on nothing but SM 9.0 -- while
    withholding `sm_121a` from the SM 12.1 GPU it was made for.

    ## What this does not know

    Whether one baseline capability's feature set contains another's, which nothing records and which
    is not implied by the version ordering: `isJetson` says that 7.2 and 8.7 are Jetson capabilities
    and nothing relates their features to 7.5 and 8.6.

    It does not need to. The closure answers whether a GPU satisfies a *stated minimum version*, which
    is what a sample's `minCudaCapability` is and what a builder is chosen by -- not whether a
    particular cubin will load, which is a different relation (same major, minor at least as high, or
    PTX and a JIT). The code the builder runs was compiled for its own capabilities by the package
    set, so that question does not arise here.

    ## Why the argument is a list

    A machine with several GPUs advertises the union of their closures, not the closure of the most
    capable, because an architecture-specific capability belongs to one GPU alone: a host with a 9.0
    and a 10.0 can run `sm_90a`, which a host with only the 10.0 cannot.

    A capability is a GPU here, never a feature set -- no GPU *is* 9.0a, that names code an SM 9.0 GPU
    can run -- and passing one is an error rather than a synonym for its base capability. The two are
    distinct sets standing in a compatibility relation, and they only look like one ordered set
    because they are spelled alike.

    # Type

    ```
    getCudaSystemFeatures :: (cudaCapabilities :: List CudaCapability) -> List String
    ```

    # Inputs

    `cudaCapabilities`

    : The capabilities of the GPUs the builder has

    # Examples

    :::{.example}
    ## `_cuda.lib.getCudaSystemFeatures` usage examples

    ```nix
    # In a NixOS configuration, for a builder with a single RTX 4090:
    nix.settings.system-features =
      [ "big-parallel" "cuda" ] ++ pkgs._cuda.lib.getCudaSystemFeatures [ "8.9" ];
    => [ "big-parallel" "cuda" "cuda-sm-35" ... "cuda-sm-89" ]
    ```
    :::
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

      # Whether a GPU which is `cudaCapability` can run code built for `required`, by the rules above.
      # `required` is a capability the db knows and `cudaCapability` is a GPU, so each branch is the
      # membership test its flavour calls for rather than a comparison on the version axis.
      canRun =
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
          lib.filter (canRun cudaCapability) _cuda.db.allSortedCudaCapabilities
        );
    in
    lib.unique (lib.concatMap featuresFor cudaCapabilities);

  /**
    The Nix system feature naming a CUDA capability.

    Both sides of the match are built by this function -- the requirement a derivation states and the
    advertisement `getCudaSystemFeatures` produces -- because Nix matches system features exactly and
    two independent spellings which drift apart do not fail. They leave every gated derivation
    unschedulable, which is indistinguishable from owning no builder that can run it.

    # Type

    ```
    mkCudaSystemFeature :: (cudaCapability :: CudaCapability) -> String
    ```

    # Inputs

    `cudaCapability`

    : The CUDA capability to name

    # Examples

    :::{.example}
    ## `_cuda.lib.mkCudaSystemFeature` usage examples

    ```nix
    mkCudaSystemFeature "8.9"
    => "cuda-sm-89"
    ```
    :::
  */
  mkCudaSystemFeature = cudaCapability: "cuda-sm-${_cuda.lib.dropDots cudaCapability}";
}
