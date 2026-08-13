{
  cuda_cudart,
  cuda_nvtx,
  lib,
  libdeflate,
  lz4,
  mkSamples,
  nvcomp,
  zlib,
}:
let
  # nvCOMP ships a CMake package config, and it cannot be used here. `nvcomp-config.cmake` takes
  # `file(REAL_PATH ...)` of its own directory and then hunts for `nvcomp.h` and `libnvcomp.so` at
  # fixed offsets from that, which no split `dev`/`include`/`lib` layout can satisfy. Configuring a
  # three-line `find_package(nvcomp REQUIRED)` against the `dev` output stops at
  #   CMake Error at .../nvcomp-5.0.0.6-dev/lib/cmake/nvcomp/nvcomp-config.cmake:137 (message):
  #     Header directory containing file nvcomp.h was not found relative to
  #     .../nvcomp-5.0.0.6-dev/lib/cmake/nvcomp!
  # and the usual escape hatch does not work either: pointing it at a `symlinkJoin`-shaped prefix
  # whose `include` and `lib` really do sit side by side fails identically, because `REAL_PATH`
  # resolves the symlinked config directory back into the `dev` store path before searching.
  #
  # The imported targets it would have defined are declared here instead, pointing at the outputs
  # which really hold each file -- the same shape cuTENSOR's and cuSPARSELt's own CMakeLists use.
  importedTargets = ''
    add_library(nvcomp::nvcomp SHARED IMPORTED)
    set_target_properties(nvcomp::nvcomp PROPERTIES
      IMPORTED_LOCATION "${lib.getLib nvcomp}/lib/libnvcomp.so"
      INTERFACE_INCLUDE_DIRECTORIES "${lib.getInclude nvcomp}/include")
    add_library(nvcomp::nvcomp_cpu SHARED IMPORTED)
    set_target_properties(nvcomp::nvcomp_cpu PROPERTIES
      IMPORTED_LOCATION "${lib.getLib nvcomp}/lib/libnvcomp_cpu.so"
      INTERFACE_INCLUDE_DIRECTORIES "${lib.getInclude nvcomp}/include")
    find_package(CUDAToolkit REQUIRED)
  '';
in
mkSamples {
  component = nvcomp;
  manifestPath = ./samples.json;
  subtrees = [ "nvCOMP" ];
  buildInputs = [
    cuda_cudart
    cuda_nvtx
    libdeflate
    lz4
    zlib
  ];

  sampleArgsFor = sampleRoot: {
    postPatch = ''
      substituteInPlace ${sampleRoot}/CMakeLists.txt \
        --replace-fail 'find_package(nvcomp REQUIRED)' ${lib.escapeShellArg importedTargets}

      # Both projects pin every target to a hard-coded architecture list, which overrides
      # CMAKE_CUDA_ARCHITECTURES exactly as the `CUDA_ARCHITECTURES OFF` that buildSample already
      # rewrites does.
      sed --regexp-extended --in-place \
        '/set_property\(TARGET .+ PROPERTY CUDA_ARCHITECTURES \$\{GPU_ARCHS\}\)/Id' \
        ${sampleRoot}/CMakeLists.txt
    '';

    # Both projects were carried here as broken, under a `nvcompBatchedApiChanged` problem which
    # said they are written against the nvCOMP 4.x batched API that 5.0.0.6 renamed. That was
    # measured against an earlier CUDALibrarySamples revision and does not describe this one: at
    # 2025-10-09 both compile against nvCOMP 5.0.0.6, and the two files the problem named --
    # `high_level_quickstart_example.cpp` and `low_level_quickstart_example.cpp` -- are among the ten
    # executables `nvCOMP/examples` now produces.
    #
    # `nvCOMP/benchmarks` did fail, but for an unrelated reason which the batched-API message hid:
    # `benchmark_hlif.hpp` includes `nvtx3/nvToolsExt.h`, so without `cuda_nvtx` among the
    # `buildInputs` the compile stopped at
    #   nvCOMP/benchmarks/benchmark_hlif.hpp:40:10: fatal error: nvtx3/nvToolsExt.h: No such file or
    #     directory
    # before reaching any nvCOMP call at all. That is what the problem was really recording, and it
    # is a missing input rather than a defect: with `cuda_nvtx` present all nine
    # `benchmark_*_chunked` targets build. A problem entry which names the wrong cause is worse than
    # none, because the check that would have caught the change was switched off by it.
    #
    # The program lists in the manifest are still CMake's own answer rather than a reading of the
    # sources, and it still matters which inputs are present: `gzip_gpu_decompression` is built
    # because zlib is a `buildInput` below while `zstd_cpu_compression` is not because zstd is not,
    # from structurally identical `if()` conditions; `nvcomp_gds` sits behind `BUILD_GDS_EXAMPLE`,
    # which defaults OFF; and `benchmark_crc32` is skipped for want of libcurand, which CMake says
    # in as many words: "Skipping CRC32 benchmark, CUDA::curand_static not found". Now that both
    # projects compile, `buildSample` checks those lists against the executables produced rather
    # than against CMake's file API, so changing the `buildInputs` below without regenerating the
    # manifest fails rather than drifts.
  };
}
