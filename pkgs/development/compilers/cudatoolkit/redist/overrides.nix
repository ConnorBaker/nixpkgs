final: prev:
let
  inherit (prev) lib pkgs;
  # cudaVersionOlder : Version -> Boolean
  cudaVersionOlder = lib.versionOlder final.cudaVersion;
  # cudaVersionAtLeast : Version -> Boolean
  cudaVersionAtLeast = lib.versionAtLeast final.cudaVersion;
  # cudaVersionAtMost : Version -> Boolean
  cudaVersionAtMost = flip versionAtLeast cudaVersion;
  # cudaVersionBounded : Version -> Version -> Boolean
  # NOTE: This is inclusive on both ends.
  cudaVersionBounded = min: max: cudaVersionAtLeast min && cudaVersionAtMost max;

  inherit (builtins) hasAttr;
  inherit (final) cudaVersion addBuildInputs addAutoPatchelfIgnoreMissingDeps;
  inherit (prev.lib.attrsets) filterAttrs optionalAttrs;
  inherit (prev.lib.lists) optionals;
  inherit (prev.lib.strings) versionAtLeast;
  inherit (prev.lib.trivial) flip pipe;
  inherit (prev.pkgs.stdenv.hostPlatform) isx86_64 isAarch64 isPower64;
  inherit
    (prev.pkgs)
    pkgsBuildHost # for nativeBuildInputs
    pkgsHostTarget # good ol' pkgs, for buildInputs
    ;
in
  filterAttrs (attr: _: (hasAttr attr prev)) {
    ### Overrides to fix the components of cudatoolkit-redist

    # Attributes that don't exist in the previous set are removed.
    # That means only overrides can go here, and not new expressions!

  libcufile = prev.libcufile.overrideAttrs (oldAttrs: {
    buildInputs = oldAttrs.buildInputs ++ [
      final.libcublas.lib
      pkgs.numactl
      pkgs.rdma-core
    ];
    # libcuda needs to be resolved during runtime
    autoPatchelfIgnoreMissingDeps =
      ["libcuda.so.1"]
      # Before 12.0 libcufile depends on itself for some reason.
      ++ lib.optionals (cudaVersionOlder "12.0") [
        "libcufile.so.0"
      ];
  });

  libcusolver = final.addBuildInputs prev.libcusolver (
    # Always depends on this
    [final.libcublas.lib]
    # Dependency from 12.0 and on
    ++ lib.optionals (cudaVersionAtLeast "12.0") [
      final.libnvjitlink.lib
    ]
    # Dependency from 12.1 and on
    ++ lib.optionals (cudaVersionAtLeast "12.1") [
      final.libcusparse.lib
    ]
  );

  libcusparse = final.addBuildInputs prev.libcusparse (
    lib.optionals (cudaVersionAtLeast "12.0") [
      final.libnvjitlink.lib
    ]
  );

  cuda_gdb = final.addBuildInputs prev.cuda_gdb (
    # x86_64 only needs gmp from 12.0 and on
    lib.optionals (cudaVersionAtLeast "12.0") [
      pkgs.gmp
    ]
  );

  cuda_nvcc = prev.cuda_nvcc.overrideAttrs (_: {
    # Required by cmake's enable_language(CUDA) to build a test program
    # When implementing cross-compilation support: this is
    # final.pkgs.targetPackages.cudaPackages.cuda_cudart
    env = {
      # Given the multiple-outputs each CUDA redist has, we can specify the exact components we
      # need from the package. CMake requires:
      # - the cuda_runtime.h header, which is in the dev output
      # - the dynamic library, which is in the lib output
      # - the static library, which is in the static output
      cudartInclude = "${final.cuda_cudart.dev}";
      cudartLib = "${final.cuda_cudart.lib}";
      cudartStatic = "${final.cuda_cudart.static}";
    };

    # Point NVCC at a compatible compiler

    # Desiredata: whenever a package (e.g. magma) adds cuda_nvcc to
    # nativeBuildInputs (offsets `(-1, 0)`), magma should also source the
    # setupCudaHook, i.e. we want it the hook to be propagated into the
    # same nativeBuildInputs.
    #
    # Logically, cuda_nvcc should include the hook in depsHostHostPropagated,
    # so that the final offsets for the propagated hook would be `(-1, 0) +
    # (0, 0) = (-1, 0)`.
    #
    # In practice, TargetTarget appears to work:
    # https://gist.github.com/fd80ff142cd25e64603618a3700e7f82
    depsTargetTargetPropagated = [
      final.setupCudaHook
    ];
  });

  cuda_nvprof = prev.cuda_nvprof.overrideAttrs (oldAttrs: {
    nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [ pkgs.addOpenGLRunpath ];
    buildInputs = oldAttrs.buildInputs ++ [ final.cuda_cupti.lib ];
    # libcuda needs to be resolved during runtime
    autoPatchelfIgnoreMissingDeps = ["libcuda.so.1"];
  });

  cuda_demo_suite = final.addBuildInputs prev.cuda_demo_suite [
    pkgs.freeglut
    pkgs.libGLU
    pkgs.libglvnd
    pkgs.mesa
    final.libcufft.lib
    final.libcurand.lib
  ];

    # nsight_compute = prev.nsight_compute.overrideAttrs (oldAttrs: {
    #   nativeBuildInputs =
    #     oldAttrs.nativeBuildInputs
    #     ++ (
    #       if (versionOlder prev.nsight_compute.version "2022.2.0")
    #       then [pkgs.qt5.wrapQtAppsHook]
    #       else [pkgs.qt6.wrapQtAppsHook]
    #     );
    #   buildInputs =
    #     oldAttrs.buildInputs
    #     ++ (
    #       if (versionOlder prev.nsight_compute.version "2022.2.0")
    #       then [pkgs.qt5.qtwebview]
    #       else [pkgs.qt6.qtwebview]
    #     );
    # });

  nvidia_driver = prev.nvidia_driver.overrideAttrs (oldAttrs: {
    # libcuda needs to be resolved during runtime
    autoPatchelfIgnoreMissingDeps = ["libcuda.so.1"];
    # No need to support this package as we have drivers already
    # in linuxPackages.
    meta.broken = true;
  });
}
