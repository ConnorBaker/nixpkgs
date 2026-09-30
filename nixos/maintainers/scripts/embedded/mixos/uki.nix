# MixOS's kernel and initrd (./default.nix) as a UKI, made as NixOS's uki.nix makes the NixOS image's: the same
# ukify and systemd-stub, with the command line MixOS's tests boot with (less their `debug`).
# Arguments: those of ./default.nix.
{
  nixpkgs ? ../../../../..,
  ...
}@args:
let
  pkgs = import nixpkgs { };
  config = (import ./default.nix args).config;
  inherit (config.system.build) toplevel;
  kernel = config.boot.kernelPackages.kernel;
in
pkgs.runCommand "mixos.efi" { } ''
  mkdir -p $out
  ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
    --linux=${toplevel}/kernel \
    --initrd=${toplevel}/initrd \
    --cmdline="console=ttyS0,115200" \
    --stub=${pkgs.buildPackages.systemdUkify}/lib/systemd/boot/efi/linuxx64.efi.stub \
    --uname=${kernel.modDirVersion} \
    --os-release=@${config.system.build.etc}/os-release \
    --efi-arch=x64 \
    --output=$out/mixos.efi
''
