{
  cuda_cudart,
  cuda_nvcc,
  cuda_nvrtc,
  lib,
  libcublas,
  libcusparse,
  mkSamples,
}:
let
  sampleArgs = {
    # The only project here which links `-lcuda`. `cuda_cudart` keeps the driver stub in a `stubs`
    # subdirectory of its single output rather than exposing a `stubs` output, so the link path has
    # to be added by hand; `removeStubsFromRunpathHook` keeps it out of the result's RUNPATH.
    "cuSPARSE/compression".NIX_LDFLAGS = "-L${cuda_cudart}/lib/stubs";

    # The only project here which uses NVRTC -- it compiles the user-defined operators for
    # `cusparseSpMMOp` at runtime -- but its CMakeLists never adds NVRTC to the link line, so it
    # fails with a page of undefined `nvrtc*` references. Patched rather than worked around with
    # `NIX_LDFLAGS`, so that the library is also what CMake believes it is linking.
    "cuSPARSE/spmm_csr_op" = {
      buildInputs = [
        (lib.getInclude cuda_nvrtc)
        (lib.getLib cuda_nvrtc)
      ];
      postPatch = ''
        substituteInPlace cuSPARSE/spmm_csr_op/CMakeLists.txt \
          --replace-fail 'PUBLIC cudart cusparse' 'PUBLIC cudart cusparse nvrtc'
      '';
    };
  };
in
mkSamples {
  component = libcusparse;
  manifestPath = ./samples.json;
  subtrees = [ "cuSPARSE" ];
  buildInputs = [
    cuda_cudart
    libcublas
    (lib.getInclude cuda_nvcc)
  ];
  inherit sampleArgs;
}
