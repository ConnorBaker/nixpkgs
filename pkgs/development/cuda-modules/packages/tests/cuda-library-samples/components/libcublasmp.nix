{
  cuda_nvml_dev,
  lib,
  libcublas,
  libcublasmp,
  libnvshmem,
  mkSamples,
  mpi,
  nccl,
}:
mkSamples {
  component = libcublasmp;
  subtrees = [ "cuBLASMp" ];
  defaults.buildInputs = [
    cuda_nvml_dev
    libcublas
    libnvshmem
    mpi
    nccl
  ];

  defaults = {
    # FindMPI executes compiler wrappers under strictDeps.
    nativeBuildInputs = [ mpi ];

    # Upstream does not discover these paths; the device NVSHMEM library is a separate archive.
    cmakeFlags = [
      (lib.cmakeFeature "CUBLASMP_INCLUDE_DIRECTORIES" "${lib.getInclude libcublasmp}/include")
      (lib.cmakeFeature "CUBLASMP_LIBRARIES" "${lib.getLib libcublasmp}/lib/libcublasmp.so")
      (lib.cmakeFeature "NCCL_INCLUDE_DIRECTORIES" "${lib.getDev nccl}/include")
      (lib.cmakeFeature "NCCL_LIBRARIES" "${lib.getLib nccl}/lib/libnccl.so")
      (lib.cmakeFeature "NVSHMEM_INCLUDE_DIRECTORIES" "${lib.getInclude libnvshmem}/include")
      (lib.cmakeFeature "NVSHMEM_HOST_LIBRARIES" "${lib.getLib libnvshmem}/lib/libnvshmem_host.so")
      (lib.cmakeFeature "NVSHMEM_DEVICE_LIBRARIES" "${lib.getLib libnvshmem}/lib/libnvshmem_device.a")
    ];

    expectedFailure = {
      message =
        "The cuBLASMp samples call cublasMpMatmulDescriptorAttributeSet, which cuBLASMp"
        + " ${libcublasmp.version} does not declare; every CUDA package set in Nixpkgs ships that"
        + " same version. The subtree is one CMake project, so all nine executables fail with"
        + " 'identifier \"cublasMpMatmulDescriptorAttributeSet\" is undefined'. Upstream:"
        + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuBLASMp";
      expectedBuilderExitCode = 2;
      expectedBuilderLogEntries = [
        ''error: identifier "cublasMpMatmulDescriptorAttributeSet" is undefined''
      ];
    };
  };
}
