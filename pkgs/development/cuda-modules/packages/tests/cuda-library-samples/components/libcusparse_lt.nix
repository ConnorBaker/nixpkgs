{
  addDriverRunpath,
  lib,
  libcusparse,
  libcusparse_lt,
  mkSamples,
}:
let
  sharedLibraryPath = "\${CUSPARSELT_PATH}/lib64/libcusparseLt.so";
  staticLibraryPath = "\${CUSPARSELT_PATH}/lib64/libcusparseLt_static.a";

in
mkSamples {
  component = libcusparse_lt;
  subtrees = [ "cuSPARSELt" ];
  defaults.buildInputs = [ libcusparse ];

  # Upstream assumes one lib64 prefix; headers, shared and static libraries occupy separate outputs.
  defaults = {
    cmakeFlags = [
      (lib.cmakeFeature "CUSPARSELT_PATH" "${lib.getInclude libcusparse_lt}")
    ];
    postPatch = ''
      substituteInPlace "$sampleRoot/CMakeLists.txt" \
        --replace-fail ${lib.escapeShellArg sharedLibraryPath} ${lib.escapeShellArg "${lib.getLib libcusparse_lt}/lib/libcusparseLt.so"} \
        --replace-fail ${lib.escapeShellArg staticLibraryPath} ${lib.escapeShellArg "${lib.getStatic libcusparse_lt}/lib/libcusparseLt_static.a"}
    '';
  };

  # Only static executables embed prebuilt NVIDIA fatbins; their architectures are not ours to choose.
  fixups.cuSPARSELt =
    lib.mapAttrs
      (_: program: {
        programsWithDeviceCodeFromPrebuiltLibrary = [ program ];
        # The static archive loads libcuda.so.1 through this path (tested on RTX 4090).
        invocations.${program}.runtimeEnv.LD_LIBRARY_PATH = "${addDriverRunpath.driverLink}/lib";
      })
      {
        matmul = "matmul_example_static";
        matmul_advanced = "matmul_advanced_example_static";
      };
}
