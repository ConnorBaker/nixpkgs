{
  autoAddDriverRunpath,
  addDriverRunpath,
  backendStdenv,
  cmake,
  cuda_cccl,
  cuda_cudart,
  cuda_cupti,
  cuda_nvcc,
  cuda_nvrtc,
  cuda_opencl,
  lib,
  libcublas,
  libcufft,
  libcurand,
  libcusolver,
  libcusparse,
  libnpp,
  libnvjitlink,

  testWithGpuAccess ? false,
  testCudaCupti ? false,
}:
let
  inherit (lib.lists) optionals;
  inherit (lib.strings)
    cmakeBool
    cmakeFeature
    cmakeOptionType
    concatStringsSep
    ;

  ignoredTests =
    [
      # Expects certain deprecation warnings to be on stdout
      "RunCMake.CMP0104"

      # TODO: Output is not as expected?
      "RunCMake.ABI"
      "RunCMake.CheckSourceCompiles"
      "RunCMake.CheckSourceRuns"
      "RunCMake.CUDA_architectures"
      "RunCMake.try_compile"
    ]

    # Requires GPU access?
    # TODO: CMake builds and then runs these immediately -- we need to patch them
    # with autoAddDriverRunpath so they can load the driver. How do we do this?
    ++ optionals (!testWithGpuAccess) [
      "Cuda.StubRPATH"
      "Cuda.WithC"
      "Cuda.ObjectLibrary"
      "Cuda.SharedRuntimePlusToolkit"
      "Cuda.StaticRuntimePlusToolkit"
      "CudaOnly.WithDefs"
      "CudaOnly.SeparateCompilationPTX"
      "CudaOnly.GPUDebugFlag"
      "CudaOnly.ArchSpecial"
      "CudaOnly.Fatbin"
      "CudaOnly.SharedRuntimePlusToolkit"
      "CudaOnly.StaticRuntimePlusToolkit"
    ];
in
backendStdenv.mkDerivation (finalAttrs: {
  strictDeps = true;

  pname = "cmake-cuda-tests";
  inherit (cmake) version;
  inherit (cmake) src;

  cmakeFlags = [
    # Force tests to be built
    (cmakeBool "BUILD_TESTING" true)

    # We only care about the tests; don't rebuild CMake in its entirety
    (cmakeOptionType "PATH" "CMake_TEST_EXTERNAL_CMAKE" "${lib.getBin cmake}/bin")

    # NOTE: Per the docs, Find* tests are enabled by undocumented CMake options.
    # https://gitlab.kitware.com/cmake/cmake/-/blob/90caa3880f345305025048d8f49e4ab1c35b39e1/Tests/README.rst
    # NOTE: Most of the configuratios can be found in their .gitlab/ci directory and have CUDA in the name:
    # https://gitlab.kitware.com/cmake/cmake/-/tree/b7c067c214dad0f5193830ff4ebf9ed7f8476cfd/.gitlab/ci

    # TODO: Split into multiple tests: this can also be "Clang"... we don't support Clang currently, but we *could*
    # https://github.com/Kitware/CMake/blob/90caa3880f345305025048d8f49e4ab1c35b39e1/.gitlab/ci/configure_cuda11.8_minimal_nvidia.cmake
    # https://github.com/Kitware/CMake/blob/90caa3880f345305025048d8f49e4ab1c35b39e1/.gitlab/ci/configure_cuda12.2_clang.cmake
    (cmakeFeature "CMake_TEST_CUDA" "NVIDIA")

    # TODO: Multiplex
    # https://github.com/Kitware/CMake/blob/90caa3880f345305025048d8f49e4ab1c35b39e1/.gitlab/ci/configure_cuda12.2_nvidia.cmake
    (cmakeBool "CMake_TEST_CUDA_CUPTI" testCudaCupti)

    # Pass arguments to the ctest executable when run through the CMake test target.
    # Nixpkgs uses `make test` so this is necessary unless we want a custom checkPhase.
    # For more on the options available to ctest, see:
    # https://cmake.org/cmake/help/book/mastering-cmake/chapter/Testing%20With%20CMake%20and%20CTest.html#testing-using-ctest
    (cmakeFeature "CMAKE_CTEST_ARGUMENTS" (
      concatStringsSep ";" [
        # Run only tests with the CUDA label
        "-L"
        "CUDA"
        # Exclude ignored tests
        "-E"
        "'${concatStringsSep "|" ignoredTests}'"
      ]
    ))
  ];

  nativeBuildInputs = [ cmake ];

  nativeCheckInputs = [
    cmake
    cuda_nvcc
  ];

  checkInputs = [
    cuda_cccl.dev
    cuda_cudart
    cuda_nvrtc
    cuda_opencl
    libcublas
    libcufft
    libcurand
    libcusolver
    libcusparse
    libnpp
    libnvjitlink
  ] ++ optionals testCudaCupti [ cuda_cupti ];

  doCheck = true;

  installPhase = ''
    touch "$out"
  '';

  passthru.tests = {
    # Run with:
    # --extra-sandbox-paths "/dev/dri $(echo /dev/nvidia*) $(nix path-info /run/opengl-driver)=/run/opengl-driver"
    cuda-test-impure =
      (finalAttrs.finalPackage.override { testWithGpuAccess = true; }).overrideAttrs
        (prevAttrs: {
          preCheck =
            prevAttrs.preCheck or ""
            + ''
              export LD_LIBRARY_PATH="${addDriverRunpath.driverLink}/lib"
            '';
        });
  };
})
