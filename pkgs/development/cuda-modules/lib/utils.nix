{ cudaLib, lib }:
let
  inherit (cudaLib.utils)
    dotsToUnderscores
    mkFailedAssertionsString
    trimComponents
    ;
in
{
  /**
    Returns a boolean indicating whether the package is broken as a result of `finalAttrs.passthru.brokenAssertions`,
    optionally logging evaluation warnings for each reason.

    NOTE: This function requires `finalAttrs.passthru.brokenAssertions` to be a list of assertions and
    `finalAttrs.finalPackage.name` to be available.

    # Type

    ```
    mkMetaBroken :: (warn :: Bool) -> (finalAttrs :: AttrSet) -> Bool
    ```

    # Inputs

    `warn`

    : A boolean indicating whether to log warnings

    `finalAttrs`

    : The final attributes of the package
  */
  mkMetaBroken =
    warn: finalAttrs:
    let
      failedAssertionsString = mkFailedAssertionsString finalAttrs.passthru.brokenAssertions;
      hasFailedAssertions = failedAssertionsString != "";
    in
    lib.warnIf (warn && hasFailedAssertions)
      "Package ${finalAttrs.finalPackage.name} is marked as broken due to the following failed assertions:${failedAssertionsString}"
      hasFailedAssertions;

  /**
    Returns a list of bad platforms for a given package if assertsions in `finalAttrs.passthru.platformAssertions` fail,
    optionally logging evaluation warnings for each reason.

    NOTE: This function requires `finalAttrs.passthru.platformAssertions` to be a list of assertions and
    `finalAttrs.finalPackage.name` and `finalAttrs.finalPackage.stdenv` to be available.

    # Type

    ```
    mkMetaBadPlatforms :: (warn :: Bool) -> (finalAttrs :: AttrSet) -> List String
    ```
  */
  mkMetaBadPlatforms =
    warn: finalAttrs:
    let
      failedAssertionsString = mkFailedAssertionsString finalAttrs.passthru.platformAssertions;
      hasFailedAssertions = failedAssertionsString != "";
      finalStdenv = finalAttrs.finalPackage.stdenv;
    in
    lib.warnIf (warn && hasFailedAssertions)
      "Package ${finalAttrs.finalPackage.name} is unsupported on this platform due to the following failed assertions:${failedAssertionsString}"
      (
        lib.optionals hasFailedAssertions (
          lib.unique [
            finalStdenv.buildPlatform.system
            finalStdenv.hostPlatform.system
            finalStdenv.targetPlatform.system
          ]
        )
      );

  /**
    Replaces dots in a string with underscores.

    # Type

    ```
    dotsToUnderscores :: (str :: String) -> String
    ```

    # Inputs

    `str`

    : The string for which dots shall be replaced by underscores

    # Examples

    :::{.example}
    ## `cudaLib.utils.dotsToUnderscores` usage examples

    ```nix
    dotsToUnderscores "1.2.3"
    => "1_2_3"
    ```
    :::
  */
  dotsToUnderscores = lib.replaceStrings [ "." ] [ "_" ];

  /**
    Create a versioned CUDA package set name from a CUDA version.

    # Type

    ```
    mkCudaPackagesVersionedName :: (cudaVersion :: Version) -> String
    ```

    # Inputs

    `cudaVersion`

    : The CUDA version to use

    # Examples

    :::{.example}
    ## `cudaLib.utils.mkCudaPackagesVersionedName` usage examples

    ```nix
    mkCudaPackagesVersionedName "1.2.3"
    => "cudaPackages_1_2_3"
    ```
    :::
  */
  mkCudaPackagesVersionedName = cudaVersion: "cudaPackages_${dotsToUnderscores cudaVersion}";

  /**
    Extracts the major, minor, and patch version from a string.

    # Type

    ```
    majorMinorPatch :: (version :: String) -> String
    ```

    # Inputs

    `version`

    : The version string

    # Examples

    :::{.example}
    ## `cudaLib.utils.majorMinorPatch` usage examples

    ```nix
    majorMinorPatch "11.0.3.4"
    => "11.0.3"
    ```
    :::
  */
  majorMinorPatch = trimComponents 3;

  /**
    Get a version string with no more than than the specified number of components.

    # Type

    ```
    trimComponents :: (numComponents :: Integer) -> (version :: String) -> String
    ```

    # Inputs

    `numComponents`
    : A positive integer corresponding to the maximum number of components to keep

    `version`
    : A version string

    # Examples

    :::{.example}
    ## `cudaLib.utils.trimComponents` usage examples

    ```nix
    trimComponents 1 "1.2.3.4"
    => "1"
    ```

    ```nix
    trimComponents 3 "1.2.3.4"
    => "1.2.3"
    ```

    ```nix
    trimComponents 9 "1.2.3.4"
    => "1.2.3.4"
    ```
    :::
  */
  trimComponents =
    n: v:
    lib.pipe v [
      lib.splitVersion
      (lib.take n)
      (lib.concatStringsSep ".")
    ];
}
