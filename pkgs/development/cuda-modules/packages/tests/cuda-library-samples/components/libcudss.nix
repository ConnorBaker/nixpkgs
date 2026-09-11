{
  addDriverRunpath,
  cudaNamePrefix,
  lib,
  libcudss,
  mkSamples,
  mpi,
  nccl,
  symlinkJoin,
}:
let
  # OPENMPI_PATH and NCCL_PATH require both headers and libraries under one root.
  rootOf =
    package:
    symlinkJoin {
      name = "${cudaNamePrefix}-libcudss-sample-${lib.getName package}-root";
      paths = [
        (lib.getDev package)
        (lib.getLib package)
      ];
    };

  # The selected sources require cuDSS 0.7.0; packaged versions are 0.6.0.5.
  requiresCudss070 = project: {
    expectedFailure = {
      message =
        "Sample cuDSS/${project} calls find_package(cudss 0.7.0 REQUIRED), and every CUDA package"
        + " set in Nixpkgs ships cuDSS ${libcudss.version}, so CMake refuses to configure it."
        + " Upstream: https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuDSS/${project}";
      expectedBuilderExitCode = 1;
      expectedBuilderLogEntries = [
        ''Could not find a configuration file for package "cudss"''
        ''requested version "0.7.0"''
      ];
    };
  };

  mgmnProjects = [
    "simple_mgmn_mode"
    "simple_mgmn_distributed_matrix"
    "test_communication_layer"
  ];

  cudss070Projects = [
    "simple_mg_mode"
    "simple_residual"
    "simple_schur_complement"
  ];

  fixups.cuDSS =
    lib.genAttrs mgmnProjects (
      project: prev: {
        buildInputs = (prev.buildInputs or [ ]) ++ [
          mpi
          nccl
        ];
        cmakeFlags = [
          (lib.cmakeFeature "OPENMPI_PATH" "${rootOf mpi}")
          (lib.cmakeFeature "NCCL_PATH" "${rootOf nccl}")
        ];
        invocations = {
          "${project}_example_openmpi" = commLayerArgs "openmpi";
          "${project}_example_nccl" = ncclArgs;
        };
      }
    )
    // lib.genAttrs cudss070Projects requiresCudss070
    // {
      simple_multithreaded_mode.invocations.simple_multithreaded_mode_example_gomp.args = [
        threadingLayer
      ];
      test_threading_layer.invocations.test_threading_layer_example_gomp.args = [
        "openmp"
        threadingLayer
      ];
    };

  # Both backends support one rank without a launcher; these arguments select the comm layer.
  commLayerArgs = backend: {
    args = [
      backend
      "${lib.getLib libcudss}/lib/libcudss_commlayer_${backend}.so"
    ];
  };

  # NCCL loads libnvidia-ml.so.1 by soname.
  ncclArgs = commLayerArgs "nccl" // {
    runtimeEnv.LD_LIBRARY_PATH = "${addDriverRunpath.driverLink}/lib";
  };

  # The simple test takes only this path; test_threading_layer also takes "openmp".
  threadingLayer = "${lib.getLib libcudss}/lib/libcudss_mtlayer_gomp.so";

in
mkSamples {
  component = libcudss;
  subtrees = [ "cuDSS" ];
  inherit fixups;
}
