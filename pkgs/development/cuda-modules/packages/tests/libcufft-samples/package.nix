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
  # `cuFFT/lto_callback_window_1d`'s NVRTC example compiles a callback at run time from a source
  # which includes <cufftXt.h>, and passes NVRTC one include directory: `-I$CUDA_PATH/include`, where
  # `CUDA_PATH` is baked in at build time as `${CUDAToolkit_BIN_DIR}/..`. That assumes a single
  # toolkit prefix with every library's headers under it, which is not how the redistributables are
  # packaged here -- `cuda_nvcc`'s prefix has no `cufftXt.h` -- so NVRTC reports
  # `catastrophic error: cannot open source file "cufftXt.h"` and the sample exits 1.
  #
  # Only the headers cuFFT's own reach: <cufftXt.h> includes <cufft.h>, which needs the CUDA runtime
  # headers. Joining more would hide which of them the run-time compile actually depends on.
  nvrtcIncludeRoot = symlinkJoin {
    name = "${cudaNamePrefix}-libcufft-sample-nvrtc-include-root";
    paths = [
      (lib.getInclude libcufft)
      (lib.getInclude cuda_cudart)
    ];
  };

  # Where the same example's callback source is installed, so that it is still there when the binary
  # is run. `SOURCE_PATH` is likewise baked in at build time, pointing at the build directory, which
  # is not in the runtime closure and does not exist afterwards: the sample opened
  # `/build/cuda-library-samples-src/cuFFT/lto_callback_window_1d/src/r2c_c2r_lto_callback_device.cu`
  # and reported `unable to open ... for reading!`.
  ltoCallbackSourceDir = "share/cuFFT/lto_callback_window_1d/src";

  sampleArgs = {
    # Both LTO callback projects build a device-side callback into a fatbin with a hand-written
    # `add_custom_command` rather than through a CMake target, and that command hard-codes
    # `--std=c++11`. That is the same pin the global patch raises in the CMakeLists -- nvcc cannot
    # parse the libstdc++ 14 headers as C++11 -- but it sits on a command line rather than in a
    # `set()`, so it has to be rewritten separately. Only these two projects have it.
    #
    # They also build one executable against `CUDA::cufft_static`, whose import target
    # `FindCUDAToolkit` only defines once it has located `libcufft_static.a`; that lives in the
    # component's `static` output, which nothing else here pulls in.
    #
    # `CUDA::culibos`, its declared dependency, is defined on the same terms and moved between CUDA
    # releases: through CUDA 12 `libculibos.a` ships inside `cuda_cudart`, which this sample already
    # has, so the target resolved for free; CUDA 13 split it into `cuda_culibos`, and without that
    # input CMake stops at `Target "r2c_c2r_legacy_callback_example" links to: CUDA::culibos but the
    # target was not found`. Gated on the toolkit version rather than on availability, so that a
    # component unavailable on a CUDA 13 set says why instead of being dropped.
    "cuFFT/lto_callback_window_1d" = {
      buildInputs = [
        (lib.getStatic libcufft)
      ]
      ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];
      postPatch = ''
        substituteInPlace cuFFT/lto_callback_window_1d/CMakeLists.txt \
          --replace-fail 'std=c++11' 'std=c++17' \
          --replace-fail \
            'CUDA_PATH=''${CUDAToolkit_BIN_DIR}/.. -DSOURCE_PATH=''${CMAKE_SOURCE_DIR}/src' \
            "CUDA_PATH=${nvrtcIncludeRoot} -DSOURCE_PATH=$out/${ltoCallbackSourceDir}"
      '';
      # The device sources the NVRTC example compiles at run time. Installed beside the binary rather
      # than left in the build directory the substitution above replaces, because a program which
      # compiles a source at run time needs that source to be part of what it is.
      postInstall = ''
        nixLog "installing the callback sources r2c_c2r_lto_nvrtc_callback_example compiles at run time"
        mkdir -p "$out/$(dirname ${ltoCallbackSourceDir})"
        cp --recursive cuFFT/lto_callback_window_1d/src "$out/${ltoCallbackSourceDir}"
      '';
    };
  };

  # `cuFFT/lto_callback_window_1d` builds three executables from one compile and only two of them
  # run, so the problem below is attached to the executable rather than to the sample: putting it on
  # the sample would withdraw the legacy callback and the NVRTC callback, both of which pass.
  testArgs."cuFFT/lto_callback_window_1d".r2c_c2r_lto_callback_example.problems.cufftOfflineLtoCallbackPlanFails =
    {
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
  manifestPath = ./samples.json;
  subtrees = [ "cuFFT" ];
  buildInputs = [
    cuda_cudart
    libnvjitlink
    cuda_nvrtc
  ];
  inherit sampleArgs testArgs;
}
