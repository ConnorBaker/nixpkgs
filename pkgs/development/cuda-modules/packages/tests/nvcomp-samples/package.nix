{
  cuda_cudart,
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

    # Both projects are written against the nvCOMP 4.x batched API, and every CUDA package set in
    # Nixpkgs ships nvCOMP 5.0.0.6, which renamed it. The compiler finds the 5.x name while
    # suggesting it for the 4.x one the sample asked for:
    #   nvCOMP/examples/high_level_quickstart_example.cpp:55:3: error: 'nvcompBatchedLZ4Opts_t' was
    #     not declared in this scope; did you mean 'nvcompBatchedLZ4CompressOpts_t'?
    #   nvCOMP/examples/low_level_quickstart_example.cpp:75:3: error:
    #     'nvcompBatchedLZ4CompressGetTempSize' was not declared in this scope; did you mean
    #     'nvcompBatchedLZ4CompressGetTempSizeSync'?
    # It is not two names: the two projects together name twenty-nine nvCOMP identifiers which
    # 5.0.0.6 does not declare -- `NVCOMP_TYPE_UINT8`, `nvcompBatchedCascadedOpts_t` and
    # `nvcompBatchedZstdOpts_t` among them -- plus signature changes which are not renames at all:
    # `nvcompBatchedLZ4DecompressAsync` now takes an options struct where the sample passes its
    # status array, so `could not convert 'device_statuses' from 'nvcompStatus_t*' to
    # 'nvcompBatchedLZ4DecompressOpts_t'`.
    #
    # A missing version, not a version bound: both projects fail this way on all seven package sets
    # (12.6, 12.8, 12.9, 13.0, 13.1, 13.2, 13.3), which resolve nvCOMP to the same 5.0.0.6
    # redistributable. No `maxCudaVersion` describes that, and there is nothing here to build them
    # against; they are broken until upstream updates them.
    #
    # Because neither project compiles, `buildSample`'s declared-against-produced check has never run
    # on either, and for a while the manifest's program lists here rested on a static parse of the
    # CMakeLists which nothing could contradict. Both were wrong, in both directions at once: it
    # declared `benchmark_crc32` for `nvCOMP/benchmarks`, which is not built, and missed the nine
    # `benchmark_*_chunked` targets which are; for `nvCOMP/examples` it invented `nvcomp_gds` and the
    # two `zstd_cpu_*` and missed the two `gdeflate_cpu_*` and `gzip_gpu_decompression`.
    #
    # None of that was readable from the sources. `nvcomp_gds` sits behind `BUILD_GDS_EXAMPLE`, which
    # defaults OFF; `gdeflate_cpu_*` behind `BUILD_GDEFLATE_CPU`, which defaults ON; and the rest
    # behind `find_package`/`find_library` results -- `gzip_gpu_decompression` is built because zlib
    # is a `buildInput` below and `zstd_cpu_compression` is not because zstd is not, from
    # structurally identical conditions. `benchmark_crc32` is skipped because libcurand is absent,
    # which CMake says in as many words: "Skipping CRC32 benchmark, CUDA::curand_static not found".
    #
    # The lists here are now CMake's own answer, taken from the file API of a configure run with
    # these very inputs, and `passthru.certifyPrograms` re-asks it on every check. That is why these
    # two projects are certified despite never being compiled, and why changing the `buildInputs`
    # below without regenerating will fail rather than drift.
    meta.problems.nvcompBatchedApiChanged = {
      kind = "broken";
      message =
        "Sample ${sampleRoot} is written against the nvCOMP 4.x batched API, and every CUDA package"
        + " set here provides nvCOMP 5.0.0.6, which renamed it: compilation fails with"
        + " \"'nvcompBatchedLZ4Opts_t' was not declared in this scope; did you mean"
        + " 'nvcompBatchedLZ4CompressOpts_t'?\" and"
        + " \"'nvcompBatchedLZ4CompressGetTempSize' was not declared in this scope; did you mean"
        + " 'nvcompBatchedLZ4CompressGetTempSizeSync'?\", identically on CUDA 12.6 through 13.3."
        + " Upstream: https://github.com/NVIDIA/CUDALibrarySamples/tree/master/${sampleRoot}";
    };
  };
}
