{
  lib,
  buildPythonPackage,
  cmake,
  config,
  cudaSupport ? config.cudaSupport,
  rocmSupport ? config.rocmSupport,
  fetchFromGitHub,
  nanobind,
  ninja,
  packaging,
  setuptools,
  torch,
  comfyui,
  symlinkJoin,
  gpuTargets ? torch.rocmPackages.clr.localGpuTargets or [ ],
}:

let
  inherit (torch) cudaPackages rocmPackages;
  rocm-sdk = symlinkJoin {
    name = "rocm-merged";
    paths = with rocmPackages; [
      clr
      rocm-comgr
      rocm-device-libs
      rocm-runtime
    ];
  };
in
buildPythonPackage (finalAttrs: {
  pname = "comfy-kitchen";
  version = "0.2.41";
  pyproject = true;

  # nixpkgs-update: no auto update
  # updated via comfyui
  src = fetchFromGitHub {
    owner = "Comfy-Org";
    repo = "comfy-kitchen";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-WbpiDqOvRxy5hTw7cpGqxOCBLJo9jnbDN0yJHm7gXEk=";
  };

  buildInputs =
    lib.optionals cudaSupport (
      with cudaPackages;
      [
        cuda_cudart
        libcublas
      ]
    )
    ++ lib.optionals rocmSupport [ rocm-sdk ];

  build-system = [
    cmake
    nanobind
    ninja
    setuptools
  ];

  nativeBuildInputs = lib.optionals cudaSupport [ cudaPackages.cuda_nvcc ];

  dependencies = [
    packaging
    torch
  ];

  dontUseCmakeConfigure = true;

  pypaBuildFlags =
    lib.optional rocmSupport "-C--global-option=--hip"
    ++ lib.optional (!cudaSupport && !rocmSupport) "-C--global-option=--no-cuda";

  env =
    lib.optionalAttrs cudaSupport {
      COMFY_CUDA_ARCHS = lib.concatMapStringsSep ";" cudaPackages.flags.dropDots torch.cudaCapabilities;
    }
    // lib.optionalAttrs rocmSupport {
      ROCM_HOME = rocm-sdk;
    }
    // lib.optionalAttrs (rocmSupport && gpuTargets != [ ]) {
      COMFY_HIP_ARCHS = (lib.concatStringsSep ";" gpuTargets);
    };

  # Upstream tests exercise the CUDA/Triton kernel backends; this build
  # might use BUILD_NO_CUDA = True, so those backends would be unavailable
  # and additionally the nix sandbox would prevent it.
  doCheck = false;

  pythonImportsCheck = [ "comfy_kitchen" ];

  meta = {
    description = "Fast kernel library for ComfyUI with multiple compute backends";
    homepage = "https://github.com/Comfy-Org/comfy-kitchen";
    license = lib.licenses.asl20;
    inherit (comfyui.meta) maintainers;
  };
})
