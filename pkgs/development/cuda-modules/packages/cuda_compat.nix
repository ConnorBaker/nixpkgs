{
  addDriverRunpath,
  backendStdenv,
  callPackage,
  buildRedist,
  config,
  lib,
  manifests,
  openssl,
  stdenv,
}:
let
  installDriver = callPackage ./cudaDriverSelector/install-driver.nix {
    redistSystem = backendStdenv.hostRedistSystem;
  };
in
buildRedist {
  # Starting with CUDA 13.4, cuda_compat is no longer in the CUDA manifest but in the driver redist.
  # See ../_cuda/manifests/nvidia-driver/README.md
  redistName = if manifests.cuda ? cuda_compat then "cuda" else "nvidia-driver";
  pname = "cuda_compat";

  # NOTE: Using multiple outputs with symlinks causes build cycles.
  # To avoid that (and troubleshooting why), we just use a single output.
  outputs = [ "out" ];

  # Install the private helper after autoPatchelf has finished with the vendor libraries.
  postPhases = [ "installCudaDriver" ];
  installCudaDriver = ''${installDriver} "$out"'';

  # The driver dlopens companion libraries by SONAME. Prefer the matching copies in
  # this package, then fall back to the host for libraries absent from the archive.
  dontUseAutoAddDriverRunpath = true;
  appendRunpaths = [ "${addDriverRunpath.driverLink}/lib" ];

  # libnvidia-pkcs11{-openssl3}.so is only shipped on x86_64-linux
  buildInputs = lib.optionals stdenv.hostPlatform.isx86_64 [
    openssl
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libnvdla_runtime.so"
    "libnvrm_gpu.so"
    "libnvrm_mem.so"
  ]
  ++ lib.optionals stdenv.hostPlatform.isx86_64 [
    # Used by libnvidia-pkcs11.so but openssl_1_1 has been removed from nixpkgs (EoL)
    "libcrypto.so.1.1"
  ];

  meta = {
    description = "CUDA user-mode driver and companion libraries for forward compatibility";
    homepage = "https://docs.nvidia.com/deploy/cuda-compatibility";
    # Keep the license independent of where the archive is fetched from.
    license = lib.licenses.nvidiaCudaRedist;
    problems = lib.optionalAttrs (!config.enableCudaDriverCompat) {
      cuda-compat-disabled = {
        kind = "broken";
        message = "cuda_compat must be explicitly enabled using config.enableCudaDriverCompat.";
      };
    };
  };
}
