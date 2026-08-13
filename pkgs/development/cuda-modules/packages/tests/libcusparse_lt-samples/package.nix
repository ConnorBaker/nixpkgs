{
  addDriverRunpath,
  cuda_cudart,
  lib,
  libcusparse,
  libcusparse_lt,
  mkSamples,
}:
let
  # Written as ordinary Nix strings, where `\${` is a literal, so that the CMake variable references
  # below read the way they do in the file being rewritten.
  sharedLibraryPath = "\${CUSPARSELT_PATH}/lib64/libcusparseLt.so";
  staticLibraryPath = "\${CUSPARSELT_PATH}/lib64/libcusparseLt_static.a";

  # The statically linked cuSPARSELt resolves the CUDA driver library through the *executable's* own
  # search path, and these executables point at nothing: they link neither cuSPARSELt nor the driver
  # as a shared object, so the driver directory is on no runpath they can see and there is no ld.so
  # cache to fall back on. Their dynamically linked siblings never notice, because
  # `libcusparseLt.so.0` carries `/run/opengl-driver/lib` on its own runpath. Upstream closes the
  # difference at the link line -- NVIDIA's documented static build command ends `-ldl -lcuda`, while
  # the CMakeLists these samples ship names `${CMAKE_DL_LIBS}` and no driver at all.
  #
  # What it costs is not a legible "cannot open libcuda.so.1": both static programs get as far as
  # `cusparseLtMatmulAlgSelectionInit` and fail there with "CUSPARSE API failed ... internal error
  # (7)", which reads like a kernel-selection or a hardware problem and is neither.
  #
  # Measured on an RTX 4090:
  #   * setting this variable makes both programs print "test PASSED" -- the samples' own comparison
  #     against a host-computed reference -- and adding the same directory to the executable's
  #     DT_RUNPATH with `patchelf` does exactly the same, so this is a search path and not an
  #     environment the library happens to like;
  #   * the contents of the directory matter, not the variable being set: `/tmp`, a nonexistent path
  #     and the empty string all leave the failure in place, while a directory holding nothing but a
  #     symlink to `libcuda.so.1` removes it, and one holding the *stub* `libcuda.so.1` instead makes
  #     the program report "CUDA driver is a stub library";
  #   * it is not an incompletely linked archive and not module loading: the failure survives
  #     `--whole-archive` and `CUDA_MODULE_LOADING=EAGER`, and reproduces from NVIDIA's own nvcc
  #     command line off the sample's Makefile;
  #   * it is not a quirk of one release: cuSPARSELt 0.6.3.2 (CUDA 12.6, where it segfaults rather
  #     than reporting an error) and 0.8.1.1 (12.9 and 13.3) all fail without this and pass with it.
  #
  # Given to the two `_static` executables alone: they are the only programs here which reach the
  # driver through the executable's search path.
  staticProgramArgs.runtimeEnv.LD_LIBRARY_PATH = "${addDriverRunpath.driverLink}/lib";
in
mkSamples {
  component = libcusparse_lt;
  manifestPath = ./samples.json;
  subtrees = [ "cuSPARSELt" ];
  buildInputs = [
    cuda_cudart
    libcusparse
  ];

  # Both projects reach into a single-prefix cuSPARSELt install: headers at
  # `${CUSPARSELT_PATH}/include`, and the two libraries spelled as file paths on the link line rather
  # than looked up with `find_library`. Nixpkgs splits those across three outputs and installs into
  # `lib`, not `lib64`, so `CUSPARSELT_PATH` alone cannot name them: pointing it at the include output
  # covers the headers, and each link line is rewritten to the output which actually holds that
  # library. Both projects build a shared and a static executable from the same source, which is why
  # the manifest declares two programs each.
  #
  # `--replace-fail`, so that a project which stopped naming these paths fails here rather than
  # quietly going back to linking a `/lib64` which does not exist in this package set.
  sampleArgsFor = sampleRoot: {
    cmakeFlags = [
      (lib.cmakeFeature "CUSPARSELT_PATH" "${lib.getInclude libcusparse_lt}")
    ];
    postPatch = ''
      substituteInPlace ${sampleRoot}/CMakeLists.txt \
        --replace-fail ${lib.escapeShellArg sharedLibraryPath} ${lib.escapeShellArg "${lib.getLib libcusparse_lt}/lib/libcusparseLt.so"} \
        --replace-fail ${lib.escapeShellArg staticLibraryPath} ${lib.escapeShellArg "${lib.getStatic libcusparse_lt}/lib/libcusparseLt_static.a"}
    '';
  };

  # The `_static` executable of each project is the same host C++ source as its dynamically linked
  # sibling -- `target_sources` names one `.cpp` for both -- so this build compiles no device code
  # for either. The shared one embeds none, and `cuobjdump` says so; the static one links
  # `libcusparseLt_static.a` and drags in the fatbins NVIDIA shipped inside it.
  #
  # What those fatbins hold is a property of the archive, and it is not even constant across this
  # package set's own members. Read back with `cuobjdump` from the binaries produced here,
  # `matmul_example_static` embeds SASS for
  #   80 86 87 89 90 90a                                     on CUDA 12.6 (cuSPARSELt 0.6.3.2)
  #   52 80 86 87 89 90 90a 100 103 120 120f 121             on CUDA 12.8 and 12.9 (0.8.1.1, cuda12)
  #   75 80 86 87 89 90 90a 100 103 120 120f 121             on CUDA 13.0 to 13.3 (0.8.1.1, cuda13)
  # while the request varies independently: 75 80 86 89 90 on 12.6, plus 100 and 120 on 12.8, plus
  # 103 and 121 from 12.9. No pairing agrees. Through 12.9 it disagrees in both directions at once
  # -- the requested 75 absent, and 87, 90a and (below 13) 52 present unasked -- and on 13.0 to 13.3
  # the archive covers the request but still carries 87, 90a and 120f beyond it, which the exact
  # comparison rejects just as firmly. What is dropped here is a comparison being asked of code this
  # build did not produce; the mismatch itself is not being called tolerable.
  #
  # Named per executable, and only for the two which link the archive. Everything else the check
  # does still applies: `cuobjdump` must succeed, they must still contain device code, and what they
  # contain is logged with a line saying it was not required to match. Both halves still bite --
  # clearing this list fails the build with "matmul_example_static embeds no SASS for requested
  # architectures: 75", and naming an executable the project does not build fails earlier still.
  sampleArgs = {
    "cuSPARSELt/matmul".programsWithDeviceCodeFromPrebuiltLibrary = [ "matmul_example_static" ];
    "cuSPARSELt/matmul_advanced".programsWithDeviceCodeFromPrebuiltLibrary = [
      "matmul_advanced_example_static"
    ];
  };

  testArgs = {
    "cuSPARSELt/matmul".matmul_example_static = staticProgramArgs;
    "cuSPARSELt/matmul_advanced".matmul_advanced_example_static = staticProgramArgs;
  };
}
