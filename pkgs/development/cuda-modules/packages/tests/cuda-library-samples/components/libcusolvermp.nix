{
  cuda_cudart,
  cuda_nvml_dev,
  lib,
  libcublas,
  libcusolver,
  libcusolvermp,
  mkSamples,
  mpi,
  nccl,
}:
mkSamples {
  component = libcusolvermp;
  subtrees = [ "cuSOLVERMp" ];
  defaults.buildInputs = [
    libcublas
    libcusolver
    mpi
    # cusolverMp.h includes nccl.h.
    nccl
    # The samples use NVML for per-rank device selection.
    cuda_nvml_dev
  ];

  defaults = {
    # FindMPI executes compiler wrappers under strictDeps.
    nativeBuildInputs = [ mpi ];

    # These cache variables otherwise silently omit the libraries from the link line.
    cmakeFlags = [
      (lib.cmakeFeature "CUSOLVERMP_INCLUDE_DIRECTORIES" "${lib.getInclude libcusolvermp}/include")
      (lib.cmakeFeature "CUSOLVERMP_LINK_DIRECTORIES" "${lib.getLib libcusolvermp}/lib")
      (lib.cmakeFeature "NCCL_INCLUDE_DIR" "${lib.getDev nccl}/include")
      (lib.cmakeFeature "NCCL_LIBRARIES" "${lib.getLib nccl}/lib/libnccl.so")
    ];

    # Driver and NVML stubs have different output layouts; neither is in the default link path.
    NIX_LDFLAGS = lib.concatStringsSep " " [
      "-L${cuda_cudart}/lib/stubs"
      "-L${lib.getOutput "stubs" cuda_nvml_dev}/lib/stubs"
    ];
  };
}
