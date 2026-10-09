# The embedded profile's system for a QEMU x86_64 guest, and (`module`) its configuration. It is cross-compiled from
# x86_64-linux, so that nixpkgs keeps the system's packages apart from its build tools, which the embedded profile's
# overlay must not reach. For glibc, another vendor field: the same machine code and libc, but a platform
# lib.systems.equals tells apart from the build platform.
{
  nixpkgs ? ../../..,
  extraKernelParams ? [ ],
  extraModules ? [ ],
  musl ? false, # the system's libc; its systemd is static musl either way
  format ? "image", # "image" (./image.nix) or "onefile" (./onefile.nix)
}:
let
  module =
    { lib, ... }:
    {
      imports = [
        ../../modules/profiles/embedded/default.nix
        ../../modules/profiles/embedded/${format}.nix
      ]
      ++ extraModules;
      nixpkgs.buildPlatform = "x86_64-linux";
      nixpkgs.hostPlatform =
        if musl then lib.systems.examples.musl64 else { config = "x86_64-pc-linux-gnu"; };
      embedded.kernelConfig = import ../../../pkgs/os-specific/linux/kernel/tiny/qemu.nix {
        inherit lib;
      };
      boot.kernelParams = [
        "console=ttyS0"
        # A QEMU guest's timer works, and ACPI describes its host bridges: no probes of either.
        "no_timer_check"
        "pci=lastbus=0"
      ]
      ++ extraKernelParams;
      users.allowNoPasswordLogin = true;
      system.stateVersion = "26.05";
    };
in
# A path, not "${nixpkgs}/nixos", which would copy the whole checkout into the store.
import (nixpkgs + "/nixos") { configuration = module; } // { inherit module; }
