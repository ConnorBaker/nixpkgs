{
  cuda_cudart,
  libcublas,
  libcusolver,
  libcusparse,
  mkSamples,
}:
let
  # Both `gesv` programs abort before solving anything, and the cause is a half-finished change in
  # the shared helper rather than anything about this machine or this cuSOLVER.
  #
  # Between the 2025-01-27 and 2025-10-09 samples, `cuSOLVER/utils/cusolver_utils.h` converted
  # `generate_random_matrix` from row-major to column-major -- it now fills `A_col = *A + *lda * j`
  # over `i` -- and `gesv` was updated to match, its calls going from `(nrhs, N, &hB, &ldb)` to
  # `(N, nrhs, &hB, &ldb)`. What was not updated is the leading dimension the helper reports: it
  # still ends `*lda = n`, which is the row-major answer. Column-major wants the number of rows.
  #
  # For the square coefficient matrix A the two agree (m == n == N) and its copy succeeds, so only
  # the right-hand side fails. There `m` is 1024 and `n` is 1, so `ldb` comes back as 1, and
  # `cudaMemcpy2D` is handed a source pitch of 8 bytes for a row 8192 bytes wide. It rejects that
  # with cudaErrorInvalidValue, which the sample turns into an uncaught `std::runtime_error`.
  #
  # Measured on libcusolver 11.7.5.82 (CUDA 12.9) on an RTX 4090, with the sample's own defaults and
  # no arguments: `CUDA error 1 at cusolver_irs_lapack.cu:122`, which is the `cudaMemcpy2D` for the
  # right-hand side. The line is only visible with stdout unbuffered -- `CUDA_CHECK` prints it with
  # `printf` and then throws, and `abort()` discards the buffer.
  #
  # Marked on the tests rather than the sample: it compiles, and it is the only project in the
  # subtree which fails, though every project here shares that helper.
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

  testArgs."cuSOLVER/gesv" = {
    cusolver_irs_lapack = gesvColumnMajorLeadingDimension "cusolver_irs_lapack";
    cusolver_irs_expert = gesvColumnMajorLeadingDimension "cusolver_irs_expert";
  };
in
mkSamples {
  component = libcusolver;
  manifestPath = ./samples.json;
  subtrees = [ "cuSOLVER" ];
  buildInputs = [
    cuda_cudart
    libcublas
    libcusparse
  ];
  inherit testArgs;
}
