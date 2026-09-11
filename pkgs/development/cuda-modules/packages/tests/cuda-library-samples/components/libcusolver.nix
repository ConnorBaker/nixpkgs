{
  libcublas,
  libcusolver,
  libcusparse,
  mkSamples,
}:
let
  gesvColumnMajorLeadingDimension = program: {
    problems.cusolverGesvLeadingDimensionRowMajor = {
      kind = "broken";
      message =
        "Sample cuSOLVER/gesv's ${program} aborts with cudaErrorInvalidValue at the cudaMemcpy2D for"
        + " its right-hand side, because cusolver_utils.h's generate_random_matrix fills the matrix"
        + " column-major while still reporting the row-major leading dimension (`*lda = n`); for an"
        + " N-by-1 right-hand side that yields ldb = 1 and a source pitch of 8 bytes for an"
        + " 8192-byte row. The square coefficient matrix is unaffected, which is why only this copy"
        + " fails. Upstream:"
        + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuSOLVER/gesv";
    };
  };

  fixups.cuSOLVER.gesv.invocations = {
    cusolver_irs_lapack = gesvColumnMajorLeadingDimension "cusolver_irs_lapack";
    cusolver_irs_expert = gesvColumnMajorLeadingDimension "cusolver_irs_expert";
  };
in
mkSamples {
  component = libcusolver;
  subtrees = [ "cuSOLVER" ];
  defaults.buildInputs = [
    libcublas
    libcusparse
  ];
  inherit fixups;
}
