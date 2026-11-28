{
  buildPackages,
  cudaDriverSelector,
  lib,
  redistSystem,
  stdenv,
}:
let
  python = buildPackages.python3.withPackages (ps: [ ps.pyelftools ]);
  manifest = [
    python.interpreter
    "-B"
    "${./elf}/manifest.py"
    redistSystem
  ];
in
if stdenv.hostPlatform.libc != "glibc" || redistSystem == "linux-aarch64" then
  lib.escapeShellArgs manifest
else
  lib.getExe (
    buildPackages.writeShellApplication {
      name = "install-cuda-driver";
      runtimeEnv = {
        inherit manifest;
        patchelf = lib.getExe buildPackages.patchelfUnstable;
        rustc = cudaDriverSelector.compileObject;
        cc = "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
        policy = "${cudaDriverSelector.dev}/lib/libnix_cuda_policy.a";
        lookupRs = ./lookup.rs;
      };
      text = builtins.readFile ./install-driver.sh;
    }
  )
