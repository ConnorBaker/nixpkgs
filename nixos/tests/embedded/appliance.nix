# The embedded profile's system for a QEMU x86_64 guest, cross-compiled (./platform.nix).
{
  nixpkgs ? ../../..,
  extraKernelParams ? [ ],
  extraModules ? [ ],
  musl ? false, # the system's libc; its systemd is static musl either way
  format ? "image", # "image" (./image.nix) or "onefile" (./onefile.nix)
}:
# A path, not "${nixpkgs}/nixos", which would copy the whole checkout into the store.
import (nixpkgs + "/nixos") {
  configuration =
    { lib, ... }:
    {
      imports = [
        ../../modules/profiles/embedded/default.nix
        ../../modules/profiles/embedded/${format}.nix
        (import ./platform.nix { inherit lib musl; })
      ]
      ++ extraModules;
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
}
