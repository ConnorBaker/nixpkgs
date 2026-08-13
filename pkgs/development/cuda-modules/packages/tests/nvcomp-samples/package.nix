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
  # Every program here but the two quickstart examples requires an input file, and none ships one:
  # run with no arguments they print a usage message -- "Must specify at least one file via
  # '-f <file>'" -- and exit 1.
  #
  # The file is taken from the checkout rather than generated, so it is pinned to the revision the
  # sources came from and staged by the same mechanism as every other sample's data. These two are
  # simply the largest files in their respective projects, which makes them the most compressible
  # things to hand: a compressor benchmark given a few hundred bytes measures its own startup.
  benchmarkInput = "benchmark_template_chunked.cuh";
  exampleInput = "high_level_quickstart_example.cpp";

  # No `expectedOutputs`, and not by oversight. These write nothing unless asked to with `-o`, and
  # unlike a sample whose only evidence of having run is a file it wrote, each of these decompresses
  # what it just compressed and aborts when the round trip does not hold. The exit status is
  # therefore load-bearing rather than vacuous here -- it is what caught `benchmark_cascaded_chunked`
  # below, which exits 0 for the eight algorithms beside it.
  withInput = input: extraArgs: {
    dataFiles = [ input ];
    args = extraArgs ++ [
      "-f"
      input
    ];
  };
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

  testArgs = {
    "nvCOMP/benchmarks" =
      lib.genAttrs [
        "benchmark_ans_chunked"
        "benchmark_bitcomp_chunked"
        "benchmark_deflate_chunked"
        "benchmark_gdeflate_chunked"
        "benchmark_lz4_chunked"
        "benchmark_snappy_chunked"
        "benchmark_zstd_chunked"
      ] (_: withInput benchmarkInput [ ])
      // {
        # Cascaded compression is the one algorithm here which reads its input as fixed-width
        # integers rather than as bytes, so text of arbitrary length is rejected outright:
        # `what(): ERROR: Invalid input data`, and the program aborts. `-m 4` pads the input to a
        # multiple of four bytes, which is all it wants; measured, `-m 8` and `-m 16` do as well.
        benchmark_cascaded_chunked = withInput benchmarkInput [
          "-m"
          "4"
        ];

        # The only one taking a positional argument, and it is required: the format to exercise the
        # high-level interface with, one of snappy, bitcomp, ans, cascaded, gdeflate, deflate, lz4 or
        # zstd. LZ4 rather than any other because it is the one the low-level quickstart uses too.
        benchmark_hlif = withInput benchmarkInput [ "lz4" ];
      };

    "nvCOMP/examples" =
      lib.genAttrs [
        "gdeflate_cpu_compression"
        "gdeflate_cpu_decompression"
        "gzip_gpu_decompression"
        "lz4_cpu_compression"
        "lz4_cpu_decompression"
        "nvcomp_crc32"
      ] (_: withInput exampleInput [ ])
      //
        lib.genAttrs
          [
            "deflate_cpu_compression"
            "deflate_cpu_decompression"
          ]
          # These two take the container as well as the file -- "Must choose an algorithm via
          # '-a <algo>', and must specify at least one file via '-f <file>'" -- and accept `deflate`,
          # `zlib` or `gzip`. The raw stream is the one the other deflate programs here produce.
          (
            _:
            withInput exampleInput [
              "-a"
              "deflate"
            ]
          );

    # `high_level_quickstart_example` and `low_level_quickstart_example` take no arguments and
    # generate their own data, so they are not named here.
  };

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
