{
  cuda_cudart,
  cuda_nvcc,
  cuda_nvrtc,
  lib,
  libcublas,
  libcusparse,
  mkSamples,
}:
mkSamples {
  component = libcusparse;
  subtrees = [ "cuSPARSE" ];
  defaults.buildInputs = [
    libcublas
    (lib.getInclude cuda_nvcc)
  ];

  fixups = {
    # The driver stub is needed at link time; the standard hook removes it from RUNPATH.
    cuSPARSE.compression.NIX_LDFLAGS = "-L${cuda_cudart}/lib/stubs";

    # Upstream uses NVRTC but omits it from the target link libraries.
    cuSPARSE.spmm_csr_op = prev: {
      buildInputs = prev.buildInputs ++ [
        (lib.getInclude cuda_nvrtc)
        (lib.getLib cuda_nvrtc)
      ];
      postPatch = ''
        substituteInPlace "$sampleRoot/CMakeLists.txt" \
          --replace-fail 'PUBLIC cudart cusparse' 'PUBLIC cudart cusparse nvrtc'
      '';
    };
  };
}
