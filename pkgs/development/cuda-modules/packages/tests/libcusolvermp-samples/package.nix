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
  manifestPath = ./samples.json;
  subtrees = [ "cuSOLVERMp" ];
  buildInputs = [
    cuda_cudart
    libcublas
    libcusolver
    mpi
    # cusolverMp.h includes "nccl.h"; without it every sample stops at that include rather than at
    # anything of its own.
    nccl
    # The link line ends `-lnvidia-ml`: the samples ask the NVIDIA Management Library which device
    # each rank should bind to. Without it every executable fails at link with
    # "cannot find -lnvidia-ml".
    cuda_nvml_dev
  ];

  # The whole subtree is one CMake project, building every executable in it, so what would otherwise
  # be per-sample overrides are a family rule: there is exactly one family.
  sampleArgsFor = _: {
    # `find_package(MPI REQUIRED)` probes with the MPI compiler wrappers, which `strictDeps` keeps
    # off PATH for a host-platform `mpi`; CMake then stops with "Could NOT find MPI_C (missing:
    # MPI_C_LIB_NAMES MPI_C_WORKS)".
    nativeBuildInputs = [ mpi ];

    # The project names NCCL and cuSOLVERMp through cache variables it never sets and never looks
    # for: unset, they expand to nothing and the link line silently loses them.
    #
    # Until the 2025-10-09 revision these were unbuildable here: `helpers.h` line 55 was an
    # unconditional `#include <cal.h>` and `build_sample` linked `cal` outright, so every sample
    # stopped at `cuSOLVERMp/helpers.h:55:10: fatal error: cal.h: No such file or directory`.
    # Upstream has since moved cuSOLVERMp off CAL: the current `helpers.h` includes only `<mpi.h>`
    # and the standard headers.
    cmakeFlags = [
      (lib.cmakeFeature "CUSOLVERMP_INCLUDE_DIRECTORIES" "${lib.getInclude libcusolvermp}/include")
      (lib.cmakeFeature "CUSOLVERMP_LINK_DIRECTORIES" "${lib.getLib libcusolvermp}/lib")
      (lib.cmakeFeature "NCCL_INCLUDE_DIR" "${lib.getDev nccl}/include")
      (lib.cmakeFeature "NCCL_LIBRARIES" "${lib.getLib nccl}/lib/libnccl.so")
    ];

    # The samples link the driver directly -- `-lcuda` and `-lnvidia-ml`, for the device queries and
    # the NVML topology lookups each rank makes before MPI_Init -- and the CMakeLists looks for both
    # in `${CMAKE_CUDA_IMPLICIT_LINK_DIRECTORIES}/stubs`, which does not exist in a splayed
    # installation. Both paths are given explicitly, as `cuSPARSE/compression` does for `-lcuda`.
    #
    # The two components stow their stubs differently, so one rule does not cover both: `cuda_cudart`
    # keeps the driver stub in a `stubs` subdirectory of its single output, while `cuda_nvml_dev`
    # has a `stubs` *output* whose payload is under `lib/stubs`. Adding the component to
    # `buildInputs` is not enough for the second -- that brings in `lib`, and the stub is not there,
    # so the link went on failing with "cannot find -lnvidia-ml" until this named the output.
    NIX_LDFLAGS = lib.concatStringsSep " " [
      "-L${cuda_cudart}/lib/stubs"
      "-L${lib.getOutput "stubs" cuda_nvml_dev}/lib/stubs"
    ];
  };
}
