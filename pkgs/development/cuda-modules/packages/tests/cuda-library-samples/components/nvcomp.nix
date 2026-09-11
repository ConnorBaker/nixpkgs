{
  cuda_nvtx,
  lib,
  libdeflate,
  lz4,
  mkSamples,
  nvcomp,
  zlib,
}:
let
  # nvcomp-config.cmake uses REAL_PATH and cannot span split outputs, even through symlinkJoin.
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
  # The projects ship no data: use their largest source files, then verify in-memory round trips.
  benchmarkInput = "benchmark_template_chunked.cuh";
  exampleInput = "high_level_quickstart_example.cpp";

  withInput = context: input: extraArgs: {
    dataFiles.${input} = "${context.src}/${context.sampleRoot}/${input}";
    args = extraArgs ++ [
      "-f"
      input
    ];
  };
  fixups = {
    nvCOMP.benchmarks.invocations =
      context:
      lib.genAttrs [
        "benchmark_ans_chunked"
        "benchmark_bitcomp_chunked"
        "benchmark_deflate_chunked"
        "benchmark_gdeflate_chunked"
        "benchmark_lz4_chunked"
        "benchmark_snappy_chunked"
        "benchmark_zstd_chunked"
      ] (_: withInput context benchmarkInput [ ])
      // {
        # Cascaded needs integer-aligned input; -m 4 pads arbitrary file lengths.
        benchmark_cascaded_chunked = withInput context benchmarkInput [
          "-m"
          "4"
        ];

        # The high-level benchmark additionally requires a positional format.
        benchmark_hlif = withInput context benchmarkInput [ "lz4" ];
      };
    nvCOMP.examples.invocations =
      context:
      lib.genAttrs [
        "gdeflate_cpu_compression"
        "gdeflate_cpu_decompression"
        "gzip_gpu_decompression"
        "lz4_cpu_compression"
        "lz4_cpu_decompression"
        "nvcomp_crc32"
      ] (_: withInput context exampleInput [ ])
      //
        lib.genAttrs
          [
            "deflate_cpu_compression"
            "deflate_cpu_decompression"
          ]
          (
            _:
            withInput context exampleInput [
              "-a"
              "deflate"
            ]
          );
  };
in
mkSamples {
  inherit fixups;
  component = nvcomp;
  subtrees = [ "nvCOMP" ];
  defaults.buildInputs = [
    cuda_nvtx
    libdeflate
    lz4
    zlib
  ];

  defaults.postPatch = ''
    substituteInPlace "$sampleRoot/CMakeLists.txt" \
      --replace-fail 'find_package(nvcomp REQUIRED)' ${lib.escapeShellArg importedTargets}

    # Per-target GPU_ARCHS overrides the configured architecture selection.
    sed --regexp-extended --in-place \
      '/set_property\(TARGET .+ PROPERTY CUDA_ARCHITECTURES \$\{GPU_ARCHS\}\)/Id' \
      "$sampleRoot/CMakeLists.txt"
  '';
}
