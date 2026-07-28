{
  cuda_cudart,
  lib,
  libcublas,
  libcutensor,
  mkSamples,
}:
let
  # Written as ordinary Nix strings, where `\${` is a literal, so that the CMake variable references
  # below read the way they do in the files being rewritten.
  importedLocationOf =
    libraryNameVariable: "\"\${CUTENSOR_ROOT}/\${LIB_DIR}/\${${libraryNameVariable}}\"";

  # Both subtrees declare cuTENSOR (and cuTENSORMg) as IMPORTED SHARED libraries whose
  # IMPORTED_LOCATION is composed from CUTENSOR_ROOT and a LIB_DIR of `/lib/<CUDA major>`. Nixpkgs
  # neither versions that directory nor keeps the headers and the shared objects under one prefix, so
  # CUTENSOR_ROOT is pointed at the include output -- which satisfies the `EXISTS` guard and the
  # `${CUTENSOR_ROOT}/include` search path -- and each IMPORTED_LOCATION is rewritten to the lib
  # output. CMake rejects an IMPORTED SHARED library whose location does not exist, so a rewrite which
  # stopped applying could not pass silently; `--replace-fail` reports it here instead.
  rewriteImportedLocation =
    libraryNameVariable:
    "--replace-fail ${lib.escapeShellArg (importedLocationOf libraryNameVariable)} ${lib.escapeShellArg "\"${lib.getLib libcutensor}/lib/\${${libraryNameVariable}}\""}";

  sampleArgs = {
    "cuTENSOR".postPatch = ''
      substituteInPlace cuTENSOR/CMakeLists.txt \
        ${rewriteImportedLocation "CUTENSOR_LIBRARY_NAME"}
    '';

    "cuTENSORMg" = {
      postPatch = ''
        substituteInPlace cuTENSORMg/CMakeLists.txt \
          ${rewriteImportedLocation "CUTENSOR_LIBRARY_NAME"} \
          ${rewriteImportedLocation "CUTENSORMG_LIBRARY_NAME"}
      '';

      # `contraction_multi_gpu` prints each device's clocks from `cudaDeviceProp::clockRate` and
      # `::memoryClockRate`, which CUDA 13 removed; nvcc says so in as many words:
      #   contraction_multi_gpu.cu(100): error: class "cudaDeviceProp" has no member "clockRate"
      #   contraction_multi_gpu.cu(102): error: class "cudaDeviceProp" has no member "memoryClockRate"
      #
      # Measured rather than read off a release note: this subtree was built against all seven package
      # sets, and it compiles on 12.6, 12.8 and 12.9 and fails with exactly those two errors on 13.0,
      # 13.1, 13.2 and 13.3. `cuTENSOR` next door builds on all seven, so the bound belongs to this
      # project and not to the component.
      maxCudaVersion = "12.9";
    };
  };

  testArgs = {
    # `blog_post` is the only sample in either subtree which reads argv, and it refuses to pick
    # defaults: `if (argc == 1)` prints `blog_post <numDevices> <scaling>` and returns EXIT_FAILURE
    # before touching a device. It then asserts that the device count is a power of two and at least
    # one, and that the scaling factor is at least one.
    #
    # One device, because that is what running it here means: it calls `cutensorMgCreate` with the
    # devices `0 .. numDevices-1` and `cudaSetDevice` on each, so a count above what the machine has
    # is not a smaller run on fewer GPUs but a failure to select a device that is not there.
    # Multi-GPU distribution is what its sibling `contraction_multi_gpu` is for, and that one
    # discovers the device count rather than being told it.
    #
    # Two is the scaling factor upstream's own text uses, and it is not merely decorative: it
    # multiplies the M1 and N1 extents, so the contraction is 16x16x8 by 16x16x8 rather than half
    # that in each. The program writes no files -- it prints its timings and
    # "Done: everything has completed successfully." -- so there is nothing here for
    # `expectedOutputs` to assert; the CHECK macro around every cuTENSORMg call exits non-zero, so
    # the exit status is not vacuous the way a silent decoder's would be.
    "cuTENSORMg".blog_post.args = [
      "1"
      "2"
    ];
  };
in
mkSamples {
  component = libcutensor;
  manifestPath = ./samples.json;
  # cuTENSOR ships its multi-GPU examples in a sibling directory rather than under `cuTENSOR/`, and
  # the one component builds both, so both have to be named here or the second could be dropped
  # from the manifest without anything noticing.
  subtrees = [
    "cuTENSOR"
    "cuTENSORMg"
  ];
  buildInputs = [
    cuda_cudart
    libcublas
  ];
  inherit sampleArgs testArgs;

  sampleArgsFor = _: {
    cmakeFlags = [
      (lib.cmakeFeature "CUTENSOR_ROOT" "${lib.getInclude libcutensor}")
    ];
  };
}
