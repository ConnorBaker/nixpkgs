# MixOS's own reference configuration (runnerMixos in its flake's devShell), built with its flake lock, on a
# kernel made like the NixOS image's: pkgs/os-specific/linux/kernel/tiny/default.nix from the same Linux and
# compiler (the nixpkgs given), with the same hardware and boot options. Its `common` already holds what
# MixOS's module.nix requires and what its init mounts.
{
  nixpkgs ? ../../../../..,
  # The revision compared (v1.13.0-3-g5ffa230).
  mixos ? "github:jmbaur/mixos/5ffa23024484c1d61ac1130b5fefda1ec97741bf",
}:
let
  flake = builtins.getFlake mixos;
  pkgs = flake.legacyPackages.x86_64-linux;
  ours = import nixpkgs { };
  inherit (ours) lib;
  kernel = import ../../../../../pkgs/os-specific/linux/kernel/tiny/default.nix {
    inherit lib;
    linux = ours.linux_7_2;
    config =
      import ../../../../../pkgs/os-specific/linux/kernel/tiny/qemu.nix { inherit lib; }
      // import ../../../../../pkgs/os-specific/linux/kernel/tiny/uefi.nix { inherit lib; }
      // (with lib.kernel; {
        BLK_DEV_LOOP = yes; # MixOS mounts its store image from a loop device
        # MixOS's initrd builder reads the kernel's module index (kmod), which a kernel without modules lacks.
        # None is built; nothing uses the exported symbols.
        MODULES = yes;
        TRIM_UNUSED_KSYMS = yes;
      });
  };
in
flake.lib.mixosSystem {
  modules = [
    {
      nixpkgs = { inherit pkgs; };
      boot.kernelPackages = pkgs.linuxPackagesFor kernel;
      init.shell = {
        action = "askfirst";
        tty = "/dev/ttyS0";
        process = "/bin/sh";
      };
    }
  ];
}
