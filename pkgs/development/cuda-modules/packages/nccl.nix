{
  _cuda,
  autoAddDriverRunpath,
  backendStdenv,
  cudaConfig,
  cccl,
  cuda_cudart,
  cuda_cuobjdump,
  cuda_nvcc,
  cudaAtLeast,
  cudaMajorMinorVersion,
  cudaNamePrefix,
  fetchFromGitHub,
  flags,
  gdrcopy,
  lib,
  patchelf,
  python3,
  rdma-core,
  runCommand,
  which,
  # passthru.updateScript
  gitUpdater,

  withGdrcopy ? true,
  withRdmaCore ? true,
}:
let
  # Compiler paths embedded in strings bypass nativeBuildInputs splicing.
  buildNvcc = cuda_nvcc.__spliced.buildHost or cuda_nvcc;
  # NCCL otherwise selects SM 100f for FP8 multicast loads. Below SM 100
  # its dispatcher excludes these kernels. The feature targets here implement
  # the generated reduction in src/device/reduce_kernel.h. Generic Blackwell
  # code and forward PTX can expose an entry point with an empty body.
  useConfiguredFp8Targets =
    cudaAtLeast "12.9"
    && !flags.cudaForwardCompat
    && lib.all (
      cap:
      lib.versionOlder cap "10.0"
      || lib.elem cap [
        "10.0a"
        "10.0f"
        "10.1a"
        "10.1f"
        "10.7a"
        "12.0a"
        "12.1a"
      ]
    ) flags.cudaCapabilities;
  inherit (_cuda.lib) _getJetsonMinSbsaCapability _mkMetaBadPlatforms;
  inherit (cudaConfig) hasJetsonCudaCapability requestedJetsonCudaCapabilities;
  sbsaJetsonCapability = _getJetsonMinSbsaCapability cudaMajorMinorVersion;
  inherit (lib)
    all
    flip
    getAttr
    getBin
    getInclude
    getLib
    licenses
    maintainers
    makeLibraryPath
    optional
    optionalString
    teams
    versionAtLeast
    versionOlder
    ;
in
backendStdenv.mkDerivation (finalAttrs: {
  __structuredAttrs = true;
  strictDeps = true;

  # NOTE: Depends on the CUDA package set, so use cudaNamePrefix.
  name = "${cudaNamePrefix}-${finalAttrs.pname}-${finalAttrs.version}";
  pname = "nccl";

  # NOTE:
  #   Compilation errors resulting from newer versions of NCCL on older releases of CUDA seem to be caused (mostly)
  #   by differences in assumed version of CCCL: using a newer CCCL with an older release of CUDA can (sometimes) allow
  #   newer versions of NCCL than what we provide here.
  version =
    if cudaAtLeast "12.0" then
      "2.32.6-1"
    else if cudaAtLeast "11.7" then
      "2.28.7-1"
    else if cudaAtLeast "11.6" then
      "2.26.6-1"
    else
      "2.25.1-1";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "nccl";
    tag = "v${finalAttrs.version}";
    hash = getAttr finalAttrs.version {
      "2.32.6-1" = "sha256-GgYG84IUJwIPCJGsg2xEGB6kbYakvutI5mH4GGytbNA=";
      "2.28.7-1" = "sha256-NM19OiBBGmv3cGoVoRLKSh9Y59hiDoei9NIrRnTqWeA=";
      "2.26.6-1" = "sha256-vkWMGXCy+dIpYCecdafmOAGlnfRxIQ5Y2ZQuMjinraI=";
      "2.25.1-1" = "sha256-3snh0xdL9I5BYqdbqdl+noizJoI38mZRVOJChgEE1I8=";
    };
    # .git_archival.txt is marked with `export-subst` attribute since
    # https://github.com/NVIDIA/nccl/commit/76c747405b7846240eaaf4e50f8ee238a5c07ba6
    # %(describe...) expression generates string like `nccl4py-v0.6.0-3-g12df1a11af`,
    # but leaves the length of the commit hash prefix up to GitHub's whim that changes
    # trim everything after `-g` to keep only more stable and predictable parts of this value
    postFetch = ''
      if [ -f "$out/bindings/nccl4py/.git_archival.txt" ]; then
        sed -E -i 's/^(describe-name: .*)-g[0-9a-h]+/\1/' "$out/bindings/nccl4py/.git_archival.txt"
      fi
    '';
  };

  outputs = [
    "out"
    "dev"
    "static"
  ];

  nativeBuildInputs = [
    # libnccl dlopens libnvidia-ml.so.1 (src/os/linux.cc), and the statically linked CUDA runtime
    # (src/Makefile: CUDARTLIB ?= cudart_static) dlopens libcuda.so.1, both by bare soname.
    autoAddDriverRunpath
    cuda_nvcc
    patchelf
    python3
    which
  ];

  buildInputs = [ cccl ];

  # nccl.h includes cuda_runtime.h. Keep this public header dependency in
  # both the stdenv and standalone pkg-config interfaces.
  propagatedBuildInputs = [ cuda_cudart ];

  env.NIX_CFLAGS_COMPILE = toString [ "-Wno-unused-function" ];

  postPatch = ''
    patchShebangs ./src/device/generate.py
    patchShebangs ./src/device/symmetric/generate.py

    substituteInPlace ./src/nccl.pc.in \
      --replace-fail 'Cflags:' $'Requires: cudart-${cudaMajorMinorVersion}\nCflags:'

    substituteInPlace ./src/Makefile \
      --replace-fail 'ar cr $@' '$(AR) cr $@'

    nixLog "patching $PWD/makefiles/common.mk to remove NVIDIA's ccbin declaration"
    substituteInPlace ./makefiles/common.mk \
      --replace-fail \
        '-ccbin $(CXX)' \
        ""
  ''
  # 2.27.3-1 was the first to introuce CXXSTD
  + optionalString (versionOlder finalAttrs.version "2.27.3-1") ''
    nixLog "patching $PWD/makefiles/common.mk to remove NVIDIA's std hardcoding"
    substituteInPlace ./makefiles/common.mk \
      --replace-fail \
        '-std=c++11' \
        '$(CXXSTD)'
  ''
  + optionalString (versionAtLeast finalAttrs.version "2.30.7-1") ''
    nixLog "patching shebang in $PWD/src/misc/generate_git_version.py"
    patchShebangs ./src/misc/generate_git_version.py
  '';

  makeFlags = [
    "CXXSTD=-std=c++17"
    "CUDA_HOME=${getBin buildNvcc}"
    "CUDA_INC=${getInclude cuda_cudart}/include"
    "CUDA_LIB=${getLib cuda_cudart}/lib"
    "NVCC_GENCODE=${flags.gencodeString}"
    "PREFIX=$(out)"
  ]
  ++ optional useConfiguredFp8Targets "NVCC_GENCODE_LDMC_FP8=${flags.gencodeString}";

  enableParallelBuilding = true;

  postFixup = ''
    _overrideFirst outputStatic "static" "lib" "out"
    moveToOutput lib/libnccl_static.a "''${!outputStatic:?}"
  ''
  # makefiles/common.mk sets RDMA_CORE=0 and MLX5DV=0, so libibverbs/libmlx5/libgdrapi are dlopen'd
  # rather than DT_NEEDED and buildInputs would not reach the runpath. Losing them is quiet: NCCL
  # logs at INFO and falls back to the socket transport.
  + optionalString (withRdmaCore || withGdrcopy) ''
    nixLog "adding dlopen'd transport libraries to libnccl's runpath"
    patchelf --add-rpath "${
      makeLibraryPath (optional withRdmaCore rdma-core ++ optional withGdrcopy gdrcopy)
    }" "''${!outputLib:?}"/lib/libnccl.so.*.*
  '';

  # nvlink records its library directories in libnccl's device code; cuda_nvcc's nvlink wrapper removes them.
  disallowedRequisites = [ (lib.getBin buildNvcc) ];

  passthru = {
    tests = lib.optionalAttrs useConfiguredFp8Targets {
      fp8Targets =
        runCommand "${finalAttrs.name}-fp8-targets"
          {
            nativeBuildInputs = [ cuda_cuobjdump ];
            AR = "${backendStdenv.cc.bintools}/bin/${backendStdenv.cc.targetPrefix}ar";
          }
          ''
            printf '%s\n' ${lib.escapeShellArgs flags.realArches} | sort -u > expected
            for suffix in "" _profile; do
              "$AR" p ${finalAttrs.finalPackage.static}/lib/libnccl_static.a "reduce_scatter_sum_f8e4m3_LDMC$suffix.cu.o" > kernel.o
              cuobjdump --dump-elf-symbols kernel.o | sed -n 's/^arch = //p' | sort -u > actual
              diff -u expected actual
            done
            touch "$out"
          '';
    };
    platformAssertions = [
      {
        message = "Pre-SBSA Jetson devices (CUDA capabilities < ${sbsaJetsonCapability}) are not supported by NCCL";
        assertion =
          !hasJetsonCudaCapability
          || all (flip versionAtLeast sbsaJetsonCapability) requestedJetsonCudaCapabilities;
      }
    ];

    updateScript = gitUpdater {
      inherit (finalAttrs) pname version;
      rev-prefix = "v";
    };
  };

  meta = {
    description = "Multi-GPU and multi-node collective communication primitives for NVIDIA GPUs";
    homepage = "https://developer.nvidia.com/nccl";
    changelog = "https://github.com/NVIDIA/nccl/releases/tag/${finalAttrs.src.tag}";
    license = licenses.bsd3;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    # NCCL does not support Jetson that need NVIDIA's linux-aarch64 (L4T) packages. Since CUDA 13.2, Orin uses SBSA.
    # https://forums.developer.nvidia.com/t/how-do-i-correctly-install-pytorch-on-jetpack-7-2/372773
    badPlatforms = _mkMetaBadPlatforms finalAttrs;
    maintainers = with maintainers; [
      mdaiter
    ];
    teams = [ teams.cuda ];
  };
})
