{
  cuda-library-samples-src,
  cudaOlder,
  lib,
  libcublas,
  mkSamples,
}:
let
  # The newer shared helper requires CUDA 13 types even in non-emulation samples.
  src =
    if cudaOlder "13" then
      builtins.fetchTarball {
        name = "cuda-library-samples-src-2025-01-27";
        url = "https://github.com/NVIDIA/CUDALibrarySamples/archive/e57b9c483c5384b7b97b7d129457e5a9bdcdb5e1.tar.gz";
        sha256 = "sha256-dEzEK6P0lQcV6WEeayuMalYavnwYsp5VA1WhVbVTJzw=";
      }
    else
      cuda-library-samples-src;

  subtrees = [
    "cuBLAS"
    "cuBLASLt"
  ];
  excludeProjects.cuBLASLt = "Aggregate entry point; build its independent child projects.";

  # Common/helpers.h requires cuda_fp4.h; builds fail on 12.6 and succeed on 12.8.
  cuBLASLtRequirements.minCudaVersion = "12.8";

  emulationHelperMissing = sampleRoot: {
    expectedFailure = {
      message =
        "Sample ${sampleRoot} calls getApproximateFixedPointEmulationWorkspaceSize, which"
        + " CUDALibrarySamples defines nowhere -- its cuBLAS/utils/cublas_utils.h declares"
        + " getFixedPointWorkspaceSizeInBytes and no such function -- so nvcc reports the identifier"
        + " as undefined. Upstream:"
        + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/${sampleRoot}";
      # The checkout has call sites but no definition; make reports nvcc's error as status 2.
      expectedBuilderExitCode = 2;
      expectedBuilderLogEntries = [
        ''error: identifier "getApproximateFixedPointEmulationWorkspaceSize" is undefined''
      ];
    };
  };

in
mkSamples {
  component = libcublas;
  inherit
    subtrees
    excludeProjects
    src
    ;
  defaults = path: lib.optionalAttrs (lib.head path == "cuBLASLt") cuBLASLtRequirements;
  fixups = {
    cuBLASLt = {
      LtFp8Matmul.minCudaCapability = "8.9";
      LtMxfp8Matmul.minCudaCapability = "10.0";
      LtNvfp4Matmul.minCudaCapability = "10.0";
    }
    // lib.optionalAttrs (!(cudaOlder "13")) {
      # Blackwell block scaling: failure on SM 8.9 was measured.
      LtBlk128x128Fp8Matmul.minCudaCapability = "10.0";
    };
    cuBLAS = lib.optionalAttrs (!(cudaOlder "13")) {
      Emulation = lib.genAttrs [ "dgemm_dynamic" "zgemm_dynamic" "gemmEx_dynamic" ] (
        _: prev: emulationHelperMissing prev.sampleRoot
      );
    };
  };
}
