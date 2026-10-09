# MixOS's own reference configuration (runnerMixos in its flake's devShell), built with its flake lock, on a kernel
# made like the NixOS image's: pkgs/os-specific/linux/kernel/tiny/default.nix from the same Linux and compiler (the
# nixpkgs given), with the same hardware and boot options. Its `common` already holds what MixOS's module.nix
# requires and what its init mounts.
# - uki: its kernel and initrd as a UKI, made as NixOS's uki.nix makes the NixOS image's: the same ukify and
#   systemd-stub, with the command line MixOS's tests boot with (less their `debug`);
# - boot: the UKI booted with UEFI firmware, as nixos/tests/embedded/boot-image.nix boots the NixOS one. At its askfirst
#   console it must run a command from its root filesystem: `echo MIXOS-OK-$((6*7))` prints MIXOS-OK-42 only if a
#   shell evaluates it (the echo of the typed line does not contain 42). red = true types 6*6 instead, which must
#   fail.
{
  nixpkgs ? ../../../..,
  # The revision compared (v1.13.0-3-g5ffa230).
  mixos ? "github:jmbaur/mixos/5ffa23024484c1d61ac1130b5fefda1ec97741bf",
  red ? false,
}:
let
  flake = builtins.getFlake mixos;
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  kernel = import ../../../../pkgs/os-specific/linux/kernel/tiny/default.nix {
    inherit lib;
    linux = pkgs.linux_7_2;
    config =
      import ../../../../pkgs/os-specific/linux/kernel/tiny/qemu.nix { inherit lib; }
      // import ../../../../pkgs/os-specific/linux/kernel/tiny/uefi.nix { inherit lib; }
      // (with lib.kernel; {
        BLK_DEV_LOOP = yes; # MixOS mounts its store image from a loop device
        # MixOS's initrd builder reads the kernel's module index (kmod), which a kernel without modules lacks.
        # None is built; nothing uses the exported symbols.
        MODULES = yes;
        TRIM_UNUSED_KSYMS = yes;
      });
  };
  inherit
    (flake.lib.mixosSystem {
      modules = [
        {
          nixpkgs.pkgs = flake.legacyPackages.x86_64-linux;
          boot.kernelPackages = flake.legacyPackages.x86_64-linux.linuxPackagesFor kernel;
          init.shell = {
            action = "askfirst";
            tty = "/dev/ttyS0";
            process = "/bin/sh";
          };
        }
      ];
    })
    config
    ;
  inherit (config.system.build) toplevel;
  ukify = pkgs.buildPackages.systemdUkify;
in
rec {
  uki = pkgs.runCommand "mixos.efi" { } ''
    mkdir -p $out
    ${ukify}/lib/systemd/ukify build \
      --linux=${toplevel}/kernel \
      --initrd=${toplevel}/initrd \
      --cmdline="console=ttyS0,115200" \
      --stub=${ukify}/lib/systemd/boot/efi/linuxx64.efi.stub \
      --uname=${config.boot.kernelPackages.kernel.modDirVersion} \
      --os-release=@${config.system.build.etc}/os-release \
      --efi-arch=x64 \
      --output=$out/mixos.efi
  '';
  esp = pkgs.runCommand "esp" { } "install -Dm444 ${uki}/mixos.efi $out/EFI/BOOT/BOOTX64.EFI";
  boot = pkgs.testers.runNixOSTest {
    name = "mixos-boot${lib.optionalString red "-red"}";
    nodes = { };
    testScript = ''
      from datetime import timedelta

      machine = create_machine(
          "${pkgs.qemu_kvm}/bin/qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 512"
          " -bios ${pkgs.OVMF.fd}/FV/OVMF.fd -drive if=virtio,format=raw,file=fat:${esp},readonly=on",
          name="mixos",
      )
      machines_qemu.append(machine)  # so that the driver ends it when a check fails
      machine.start()
      machine.wait_for_console_text("Run /init as init process", timeout=timedelta(seconds=20))

      # busybox's prompts end no line, which the driver reads the console by: type, a second apart, until the
      # shell's output line comes.
      def shell_ran(_last_try: bool) -> bool:
          machine.send_console("\necho MIXOS-OK-$((6*${if red then "6" else "7"}))\n")
          return "MIXOS-OK-42" in machine.get_console_log()

      retry(shell_ran, timeout=timedelta(seconds=20))
      machine.crash()
    '';
  };
}
