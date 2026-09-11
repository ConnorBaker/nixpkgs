{
  cudaAtLeast,
  cudaNamePrefix,
  cuda_cudart,
  cuda_culibos,
  cuda_nvrtc,
  lib,
  libcufft,
  libnvjitlink,
  mkSamples,
  symlinkJoin,
}:
let
  # The NVRTC callback needs cuFFT/runtime headers, not nvcc's single-prefix CUDA_PATH.
  nvrtcIncludeRoot = symlinkJoin {
    name = "${cudaNamePrefix}-libcufft-sample-nvrtc-include-root";
    paths = [
      (lib.getInclude libcufft)
      (lib.getInclude cuda_cudart)
    ];
  };

  # SOURCE_PATH must survive outside the build directory for runtime compilation.
  ltoCallbackSourceDir = "share/cuFFT/lto_callback_window_1d/src";

  # Its handwritten nvcc command also needs C++17; the other callbacks must remain runnable.
  fixups.cuFFT.lto_callback_window_1d = prev: {
    invocations.r2c_c2r_lto_callback_example.problems.cufftOfflineLtoCallbackPlanFails =
      offlineCallbackFailure;
    buildInputs =
      prev.buildInputs
      ++ [
        (lib.getStatic libcufft)
      ]
      ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];
    postPatch = ''
      substituteInPlace "$sampleRoot/CMakeLists.txt" \
        --replace-fail 'std=c++11' 'std=c++17' \
        --replace-fail \
          'CUDA_PATH=''${CUDAToolkit_BIN_DIR}/.. -DSOURCE_PATH=''${CMAKE_SOURCE_DIR}/src' \
          "CUDA_PATH=${nvrtcIncludeRoot} -DSOURCE_PATH=$out/${ltoCallbackSourceDir}"
    '';
    postInstall = ''
      nixLog "installing the callback sources r2c_c2r_lto_nvrtc_callback_example compiles at run time"
      mkdir -p "$out/$(dirname ${ltoCallbackSourceDir})"
      cp --recursive "$sampleRoot/src" "$out/${ltoCallbackSourceDir}"
    '';
  };

  offlineCallbackFailure = {
    kind = "broken";
    message =
      "Sample cuFFT/lto_callback_window_1d's r2c_c2r_lto_callback_example fails at"
      + " cufftMakePlan1d with CUFFT_INTERNAL_ERROR (5), then segfaults in cufftExecC2R, because"
      + " its CHECK_ERROR macro reports a failing call without stopping. Measured against cuFFT"
      + " 11.4.1.4 (CUDA 12.9) on an RTX 4090: plan creation returns 5 with the callback fatbin"
      + " built at the compute_60 upstream pins and equally at compute_89, and with fatbin"
      + " compression on and off, so neither the pinned architecture nor the container's encoding"
      + " is the cause. The same callback compiled by NVRTC to LTO IR, in the sibling"
      + " r2c_c2r_lto_nvrtc_callback_example, makes its plan and reports an L2 error of 0, so what"
      + " this executable cannot use is the fatbin-wrapped form nvcc -dc -fatbin produces."
      + " Upstream:"
      + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuFFT/lto_callback_window_1d";
  };
in
mkSamples {
  component = libcufft;
  subtrees = [ "cuFFT" ];
  defaults.buildInputs = [
    libnvjitlink
    cuda_nvrtc
  ];
  inherit fixups;
}
