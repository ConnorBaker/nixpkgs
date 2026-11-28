{ lib, stdenv }:
[
  "/run/opengl-driver/lib"
  "/usr/lib/wsl/lib"
  "/usr/local/nvidia/lib64"
]
++ lib.optionals stdenv.hostPlatform.isAarch64 [
  "/usr/lib/aarch64-linux-gnu"
  "/usr/lib/aarch64-linux-gnu/nvidia"
  "/usr/lib/aarch64-linux-gnu/tegra"
]
++ lib.optional stdenv.hostPlatform.isx86_64 "/usr/lib/x86_64-linux-gnu"
++ [
  "/usr/lib64"
  "/usr/lib"
]
