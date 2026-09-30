# Cross-compiled from x86_64-linux, so that nixpkgs keeps the system's packages apart from its build tools,
# which the embedded profile's overlay must not reach. For glibc, another vendor field: the same machine code
# and libc, but a platform lib.systems.equals tells apart from the build platform.
{ lib, musl }:
{
  nixpkgs.buildPlatform = "x86_64-linux";
  nixpkgs.hostPlatform =
    if musl then lib.systems.examples.musl64 else { config = "x86_64-pc-linux-gnu"; };
}
