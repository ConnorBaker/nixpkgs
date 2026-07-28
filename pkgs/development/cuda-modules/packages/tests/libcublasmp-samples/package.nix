{
  cuda_cudart,
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
  manifestPath = ./samples.json;
  subtrees = [ "cuBLASMp" ];
  buildInputs = [
    cuda_cudart
    cuda_nvml_dev
    libcublas
    libnvshmem
    mpi
    nccl
  ];

  # The whole subtree is one CMake project, building every executable in it, so what would otherwise
  # be per-sample overrides are a family rule: there is exactly one family.
  sampleArgsFor = _: {
    # `find_package(MPI REQUIRED)` probes with the MPI compiler wrappers, which `strictDeps` keeps
    # off PATH for a host-platform `mpi`; CMake then stops with "Could NOT find MPI_C (missing:
    # MPI_C_LIB_NAMES MPI_C_WORKS)".
    nativeBuildInputs = [ mpi ];

    # The project names cuBLASMp, NCCL and NVSHMEM through cache variables it never sets and never
    # looks for: unset, they expand to nothing and the link line silently loses the libraries the
    # samples exist to exercise.
    #
    # Until the 2025-10-09 revision these were unbuildable here: `helpers.h` line 52 was an
    # unconditional `#include <cal.h>`, and NVIDIA's Communication Abstraction Library is a
    # transitional package no CUDA package set in Nixpkgs provides, so every sample stopped at
    # `cuBLASMp/helpers.h:52:10: fatal error: cal.h: No such file or directory`. Upstream has since
    # moved cuBLASMp off CAL -- the CMakeLists names NCCL and NVSHMEM where it named `CAL_LIBRARIES`
    # and `CAL_MPI_LIBRARIES` -- and both replacements are packaged, so these build rather than
    # needing an excuse.
    cmakeFlags = [
      (lib.cmakeFeature "CUBLASMP_INCLUDE_DIRECTORIES" "${lib.getInclude libcublasmp}/include")
      (lib.cmakeFeature "CUBLASMP_LIBRARIES" "${lib.getLib libcublasmp}/lib/libcublasmp.so")
      (lib.cmakeFeature "NCCL_INCLUDE_DIRECTORIES" "${lib.getDev nccl}/include")
      (lib.cmakeFeature "NCCL_LIBRARIES" "${lib.getLib nccl}/lib/libnccl.so")
      (lib.cmakeFeature "NVSHMEM_INCLUDE_DIRECTORIES" "${lib.getInclude libnvshmem}/include")
      (lib.cmakeFeature "NVSHMEM_HOST_LIBRARIES" "${lib.getLib libnvshmem}/lib/libnvshmem_host.so")
      # The device half is a static archive rather than a shared object, and it is a separate
      # variable on the link line: without it the device-side NVSHMEM symbols the samples call go
      # unresolved at link time.
      (lib.cmakeFeature "NVSHMEM_DEVICE_LIBRARIES" "${lib.getLib libnvshmem}/lib/libnvshmem_device.a")
    ];

    # Having lost CAL as a blocker, these samples immediately gained another: the four `pmatmul`
    # programs call `cublasMpMatmulDescriptorAttributeSet`, which the cuBLASMp Nixpkgs ships does
    # not declare. Because the subtree is a single CMake project, those four take every other
    # executable down with them, so the marking is on the family rather than on the programs which
    # are at fault.
    #
    # Measured rather than assumed: every CUDA package set from 12.6 to 13.3 resolves `libcublasmp`
    # to the same 0.8.1.2360, and its `cublasmp.h` has no such identifier -- 0 occurrences against 49
    # for `cublasMpMatmul*` in the same header, so the search was looking in the right place. There
    # is therefore no `minCudaVersion` which describes this: the bound is on the component's own
    # version, and every set is on the wrong side of it.
    #
    # This is the case the multi-revision pin exists for, and a candidate for it: a revision between
    # 2025-01-27 and 2025-10-09 would have samples which are past CAL and before this API. Finding
    # one means bisecting an untagged repository, which nobody has done -- so until then the samples
    # are honestly broken rather than pinned to a revision nobody measured.
    meta.problems.cublasmpMatmulDescriptorApiMissing = {
      kind = "broken";
      message =
        "The cuBLASMp samples call cublasMpMatmulDescriptorAttributeSet, which cuBLASMp"
        + " ${libcublasmp.version} does not declare; every CUDA package set in Nixpkgs ships that"
        + " same version. The subtree is one CMake project, so all nine executables fail with"
        + " 'identifier \"cublasMpMatmulDescriptorAttributeSet\" is undefined'. Upstream:"
        + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuBLASMp";
    };
  };
}
