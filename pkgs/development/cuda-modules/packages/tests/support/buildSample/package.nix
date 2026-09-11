# Build an independent CMake project while retaining sibling headers/helpers from the checkout.
{
  autoAddDriverRunpath,
  backendStdenv,
  cmake,
  cuda_cudart,
  cuda_cuobjdump,
  cuda_nvcc,
  cudaAtLeast,
  cudaMajorMinorVersion,
  cudaNamePrefix,
  flags,
  python3,
  lib,
}:
lib.extendMkDerivation {
  constructDrv = backendStdenv.mkDerivation;
  excludeDrvArgNames = [
    "component"
    "programsWithDeviceCodeFromPrebuiltLibrary"
    "minCudaVersion"
    "maxCudaVersion"
    "minCudaCapability"
  ];
  extendDrvArgs =
    finalAttrs:
    {
      component,
      src,
      sampleRoot,
      # Static cuSPARSELt binaries contain NVIDIA's fatbins, not device code compiled by this build.
      programsWithDeviceCodeFromPrebuiltLibrary ? [ ],
      minCudaVersion ? null,
      maxCudaVersion ? null,
      minCudaCapability ? null,
      pname ? "${component.pname}-sample-${lib.replaceStrings [ "/" ] [ "-" ] sampleRoot}",
      version ? component.version,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      cmakeFlags ? [ ],
      postPatch ? "",
      preConfigure ? "",
      passthru ? { },
      meta ? { },
      ...
    }:
    let
      requirements = finalAttrs.passthru;
      usableCudaCapabilities = lib.filter (
        capability:
        requirements.minCudaCapability == null
        || lib.versionAtLeast capability requirements.minCudaCapability
      ) backendStdenv.cudaCapabilities;
      problems =
        lib.optionalAttrs
          (requirements.minCudaVersion != null && !(cudaAtLeast requirements.minCudaVersion))
          {
            cudaVersionTooOld = {
              kind = "broken";
              message = "Sample ${sampleRoot} requires CUDA ${requirements.minCudaVersion} or newer, but this package set provides ${cudaMajorMinorVersion}.";
            };
          }
        //
          lib.optionalAttrs
            (
              requirements.maxCudaVersion != null
              && !(lib.versionAtLeast requirements.maxCudaVersion cudaMajorMinorVersion)
            )
            {
              cudaVersionTooNew = {
                kind = "broken";
                message = "Sample ${sampleRoot} was last able to build against CUDA ${requirements.maxCudaVersion}, but this package set provides ${cudaMajorMinorVersion}.";
              };
            }
        // lib.optionalAttrs (usableCudaCapabilities == [ ]) {
          noUsableCudaCapability = {
            kind = "broken";
            message = "Sample ${sampleRoot} requires compute capability ${toString requirements.minCudaCapability} or newer, but the configured capabilities are ${lib.concatStringsSep ", " backendStdenv.cudaCapabilities}.";
          };
        };
    in
    {
      __structuredAttrs = true;
      strictDeps = true;
      name = "${cudaNamePrefix}-${finalAttrs.pname}-${finalAttrs.version}";
      inherit
        pname
        version
        src
        sampleRoot
        ;
      nativeBuildInputs = [
        cmake
        python3
        cuda_nvcc
        cuda_cuobjdump
        autoAddDriverRunpath
      ]
      ++ nativeBuildInputs;
      buildInputs = [
        component
        cuda_cudart
      ]
      ++ buildInputs;

      # The standard hook enters build/ before configuring. CMAKE_SOURCE_DIR must be the project,
      # not the checkout root: upstream uses it to find ../utils and other shared files.
      cmakeDir = "../${finalAttrs.sampleRoot}";
      cmakeFlags = [
        (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" (
          lib.concatStringsSep ";" (map flags.dropDots usableCudaCapabilities)
        ))
      ]
      ++ cmakeFlags;

      # Helpers outside the project directory can override target architectures too. Patch the
      # whole component subtree, then verify the resulting binaries rather than trusting the flags.
      postPatch = ''
        nixLog "normalizing C++ standards and CUDA architecture overrides in ''${sampleRoot%%/*}"
        find "''${sampleRoot%%/*}" -type f \
          \( -name CMakeLists.txt -o -name '*.cmake' \) -exec sed --regexp-extended --in-place \
          -e 's/set\(CMAKE_(CXX|CUDA)_STANDARD[[:space:]]+11[[:space:]]*\)/set(CMAKE_\1_STANDARD 17)/I' \
          -e '/set_property\(TARGET .+ PROPERTY CUDA_ARCHITECTURES OFF\)/Id' {} +
      ''
      + postPatch;
      preConfigure = ''
        mkdir -p build/.cmake/api/v1/query
        touch build/.cmake/api/v1/query/codemodel-v2
      ''
      + preConfigure;
      installPhase = ''
        cd "$NIX_BUILD_TOP/$sourceRoot"
        runHook preInstall
        python3 ${./cmakePrograms.py} build "$out"
        runHook postInstall
      '';
      doInstallCheck = true;
      architectureCheck = builtins.toJSON {
        expected = map flags.dropDots usableCudaCapabilities;
        prebuilt = programsWithDeviceCodeFromPrebuiltLibrary;
      };
      installCheckPhase = ''
        runHook preInstallCheck
        python3 ${./checkArchitectures.py} "$architectureCheck" "$out" "$sampleRoot"
        runHook postInstallCheck
      '';
      passthru = passthru // {
        inherit component;
        # Read construction inputs, never attributes which caller passthru can shadow.
        inherit (finalAttrs) src sampleRoot;
        inherit
          minCudaVersion
          maxCudaVersion
          minCudaCapability
          usableCudaCapabilities
          ;
      };
      meta = {
        inherit (component.meta) license platforms;
        teams = component.meta.teams or [ ];
        sourceProvenance = [ lib.sourceTypes.fromSource ];
        description = "Sample ${sampleRoot} built against ${component.pname}";
      }
      // meta
      // {
        # Dependency policy has already been resolved at each input's own identity.
        # Reapplying its problem declarations here would discard package-specific allowances.
        broken =
          (meta.broken or false)
          || lib.any (input: !(input.meta.available or true)) (
            finalAttrs.buildInputs
            ++ finalAttrs.nativeBuildInputs
            ++ finalAttrs.propagatedBuildInputs or [ ]
            ++ finalAttrs.propagatedNativeBuildInputs or [ ]
          );
        problems = problems // (meta.problems or { });
      };
    };
}
