{
  backendStdenv,
  buildPackages,
  cuda_compat,
  cudaDriverSelector,
  lib,
  makeSetupHook,
  stdenv,
}:
let
  # Orin's nvgpu compute driver has its own upgrade package and BSP matrix.
  # CUDA 13.2 also uses the generic SBSA package set for Orin targets.
  enableHook =
    stdenv.hostPlatform.libc == "glibc"
    && (cuda_compat.meta.available or false)
    && backendStdenv.hostRedistSystem != "linux-aarch64"
    && !(stdenv.hostPlatform.isAarch64 && backendStdenv.cudaCapabilities == [ "8.7" ]);
  manifest = lib.optionalString enableHook "${cuda_compat}/nix-support/nix-cuda-compat";
  script =
    if enableHook then
      ./auto-add-cuda-compat-runpath.sh
    else
      builtins.toFile "no-cuda-driver-hook.sh" "";
  driverLookup = lib.optionalAttrs enableHook {
    path = "${cuda_compat}/libexec/libnix-cuda-driver-lookup.so";
    staticObject = "${cuda_compat}/libexec/nix-cuda-static-lookup.o";
    symbol = "nix_cuda_dlopen_${builtins.substring 0 32 (baseNameOf cuda_compat.outPath)}";
  };
  python = buildPackages.python3.withPackages (ps: [ ps.pyelftools ]);
in
makeSetupHook {
  name = "auto-add-cuda-compat-runpath-hook";
  substitutions = lib.optionalAttrs enableHook {
    marker = manifest;
    auditor = "${cudaDriverSelector}/lib/libnix-cuda-audit.so";
    lookup = driverLookup.path;
    inherit (driverLookup) symbol;
    interpreter = baseNameOf stdenv.cc.bintools.dynamicLinker;
    python = python.interpreter;
    fixup = "${../cudaDriverSelector/elf}/fixup.py";
    patchelf = lib.getExe buildPackages.patchelfUnstable;
  };
  passthru = { inherit enableHook manifest driverLookup; };
  meta.license = lib.licenses.mit;
} script
