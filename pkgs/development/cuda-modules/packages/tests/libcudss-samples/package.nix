{
  addDriverRunpath,
  cuda_cudart,
  cudaNamePrefix,
  lib,
  libcudss,
  mkSamples,
  mpi,
  nccl,
  symlinkJoin,
}:
let
  # The multi-GPU/multi-node examples want the *root* of each communication library -- they derive
  # `<root>/include` and `<root>/lib` themselves and check that the root is a directory -- which is
  # not a shape Nixpkgs' split outputs have. Joining the two outputs each library needs produces one,
  # rather than pointing the samples at a prefix which happens to contain only half of what they
  # look for.
  #
  # The previous revision took `OPENMPI_INCLUDE_DIRECTORIES` and `OPENMPI_LINK_DIRECTORIES` directly;
  # the current one renamed the interface to `OPENMPI_PATH`/`NCCL_PATH` and two of the three projects
  # accept nothing else, so the old flags configured nothing and the samples failed with
  # "path to the OpenMPI root directory must be set in OPENMPI_PATH".
  rootOf =
    package:
    symlinkJoin {
      # Named after the package rather than after a string repeated at the call site, so that
      # swapping one MPI implementation for another renames this instead of mislabelling it.
      name = "${cudaNamePrefix}-libcudss-sample-${lib.getName package}-root";
      paths = [
        (lib.getDev package)
        (lib.getLib package)
      ];
    };

  # Shared by every project which builds one executable per communication backend. They refuse to
  # configure unless told where MPI and NCCL live: they look for neither.
  mgmnArgs = {
    buildInputs = [
      mpi
      nccl
    ];
    cmakeFlags = [
      (lib.cmakeFeature "OPENMPI_PATH" "${rootOf mpi}")
      (lib.cmakeFeature "NCCL_PATH" "${rootOf nccl}")
    ];
    meta.problems = lib.optionalAttrs (!nccl.meta.available) {
      ncclUnavailable = {
        kind = "broken";
        message =
          "This sample builds one executable per communication backend and NCCL is one of them, but"
          + " ${nccl.name} is not available on this platform.";
      };
    };
  };

  # The projects listed below raised their floor to cuDSS 0.7.0, which none of the package sets here
  # provides: every
  # one ships 0.6.0.5. CMake says so itself and refuses to configure -- `Could not find a
  # configuration file for package "cudss" that is compatible with requested version "0.7.0"` --
  # rather than failing later in a way that needs interpreting.
  #
  # This is a component-version bound, not a CUDA-version one, so there is no `minCudaVersion` which
  # expresses it: bumping to a newer package set does not help while cuDSS stays where it is.
  requiresCudss070 = project: {
    meta.problems.cudss070Required = {
      kind = "broken";
      message =
        "Sample cuDSS/${project} calls find_package(cudss 0.7.0 REQUIRED), and every CUDA package"
        + " set in Nixpkgs ships cuDSS ${libcudss.version}, so CMake refuses to configure it."
        + " Upstream: https://github.com/NVIDIA/CUDALibrarySamples/tree/master/cuDSS/${project}";
    };
  };

  # The projects, named once. `sampleArgs` and `testArgs` are both keyed by sampleRoot and both need
  # the MGMN three, and the programs those build are named after the project too -- so writing the
  # names out per table would be three lists of the same thing, kept in step by hand.
  bySampleRoot =
    projects: f:
    lib.listToAttrs (map (project: lib.nameValuePair "cuDSS/${project}" (f project)) projects);

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

  sampleArgs =
    bySampleRoot mgmnProjects (_: mgmnArgs) // bySampleRoot cudss070Projects requiresCudss070;

  # Both multi-GPU/multi-node executables require the name of their communication backend and the
  # full path of the matching cuDSS communication layer, and refuse to do anything without them:
  # they print "this example requires passing: a) the communication backend name ... b) the
  # communication layer library" and exit 254. That, and not the absence of a launcher, is why they
  # failed. Each was then run here with the two arguments below and no launcher at all, and each
  # solved its 5x5 system and printed "Example PASSED": the sample calls `MPI_Init` itself, and Open
  # MPI's singleton initialisation gives it a one-rank `MPI_COMM_WORLD` without `mpirun`. One rank is
  # also all this machine could honestly run -- it has a single GPU, and the sample says in as many
  # words that the number of processes must not exceed the number of devices -- so wrapping the
  # invocation in `mpirun -np 1` would add a launcher without adding a rank, and gating the tests on
  # a multi-GPU builder would leave the single-GPU case, which does work, untested.
  #
  # The layer is passed explicitly rather than left to cuDSS's `CUDSS_COMM_LIB` environment variable
  # so that the test names the library it loaded.
  commLayerArgs = backend: {
    args = [
      backend
      "${lib.getLib libcudss}/lib/libcudss_commlayer_${backend}.so"
    ];
  };

  # NCCL `dlopen`s `libnvidia-ml.so.1` by soname, and nothing in this program's link chain has the
  # driver directory on its runpath, so in the sandbox -- which has no ld.so cache -- the open fails
  # and `ncclCommInitRank` returns 2. NCCL says so itself under `NCCL_DEBUG=WARN`: "Failed to open
  # libnvidia-ml.so.1: cannot open shared object file". The driver is mounted; only the search path
  # is missing, and with it this sample solves its system and prints "Example PASSED". Given to these
  # programs alone rather than to every tester, because they are the only ones which load a driver
  # library by soname at run time.
  ncclArgs = commLayerArgs "nccl" // {
    runtimeEnv.LD_LIBRARY_PATH = "${addDriverRunpath.driverLink}/lib";
  };

  backendTestArgs = project: {
    "${project}_example_openmpi" = commLayerArgs "openmpi";
    "${project}_example_nccl" = ncclArgs;
  };

  # Both multithreading examples need the threading layer named on the command line, and -- unlike
  # the MGMN pair, which share one calling convention -- they do not agree on how.
  #
  # `test_threading_layer` wants two arguments and says so: "this example requires passing at least
  # two arguments: the threading backend name (openmp) and the threading layer library".
  # `simple_multithreaded_mode` wants only the library, and passing the backend first is not
  # rejected -- it takes `openmp` *as* the library name, reports "Threading layer library name is:
  # openmp", and then fails at `cudssSetThreadingLayer` with status 3. That failure reads exactly
  # like the one from passing nothing at all, which is what made it worth running the program by
  # hand to tell the two apart: with the path alone it prints "Example PASSED".
  #
  # The library is `libcudss_mtlayer_gomp.so`. cuDSS calls it the *multithreading* layer in the file
  # name while the samples ask for a *threading* backend, so a search for "thrlayer" finds nothing
  # and suggests, wrongly, that the redistributable ships none. It does: the `lib` output has it
  # beside the two `libcudss_commlayer_*` ones. `gomp` is the GNU OpenMP runtime the sample's own
  # CMakeLists names its executable after, which is why the program is `..._example_gomp`.
  threadingLayer = "${lib.getLib libcudss}/lib/libcudss_mtlayer_gomp.so";

  testArgs = bySampleRoot mgmnProjects backendTestArgs // {
    "cuDSS/simple_multithreaded_mode".simple_multithreaded_mode_example_gomp.args = [
      threadingLayer
    ];
    "cuDSS/test_threading_layer".test_threading_layer_example_gomp.args = [
      "openmp"
      threadingLayer
    ];
  };
in
mkSamples {
  component = libcudss;
  manifestPath = ./samples.json;
  subtrees = [ "cuDSS" ];
  buildInputs = [ cuda_cudart ];
  inherit sampleArgs testArgs;
}
