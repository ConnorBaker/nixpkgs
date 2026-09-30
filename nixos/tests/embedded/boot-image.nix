# Boots the embedded image with UEFI firmware in QEMU, on the NixOS test driver as nixos/tests/boot.nix boots ISO
# images (create_machine with QEMU's own command line), reading only the serial console: the guest needs nothing
# of the driver's.
#
# verbose (default): the image with systemd logging to the console; it must reach multi-user.target and finish
#   starting up, with no failed unit, warning or error on the way.
# verbose = false: the image as shipped, which prints little and has no login prompt or shell. A unit added
#   for the check prints the system's state on the console once it has started up: it must be "running" (with
#   a failed unit, it is "degraded").
# format = "onefile": the UKI holding everything (nixos/modules/profiles/embedded/onefile.nix), booted by the
#   firmware from an ESP that has nothing else (QEMU's virtual FAT drive of a directory).
# stage1Failure = true (onefile): the image with its stage 1 made to fail (an initramfs that is not a ramfs); the
#   init must say why, and the kernel panic and reboot, which ends QEMU.
# lateDisk = true (image): the disk comes only once the kernel waits for the store's partition, hot-plugged into a
#   PCIe port (the firmware boots the UKI from a FAT drive of its own, as for onefile); the system must then boot
#   as with the disk there from the start. (The kernel of this test alone has PCIe hotplug.)
{
  nixpkgs ? ../../..,
  verbose ? true,
  extraModules ? [ ],
  musl ? false,
  format ? "image",
  stage1Failure ? false,
  lateDisk ? false,
  # The guest: MiB of memory, and CPUs. The devices this is for have 256-512 MiB and fewer than four cores.
  memory ? 512,
  cpus ? 1,
}:
assert stage1Failure -> format == "onefile";
assert lateDisk -> format == "image";
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  stateOnConsole =
    { config, ... }:
    {
      systemd.services.boot-state = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${config.systemd.package}/bin/systemctl is-system-running --wait";
          StandardOutput = "tty";
          TTYPath = "/dev/ttyS0";
        };
      };
    };
  system = import ./appliance.nix {
    inherit nixpkgs musl format;
    extraModules =
      extraModules
      ++ lib.optional verbose { boot.consoleLogLevel = 7; }
      ++ lib.optional (!verbose) stateOnConsole
      ++ lib.optional lateDisk {
        embedded.kernelConfig = with lib.kernel; {
          PCIEPORTBUS = yes;
          HOTPLUG_PCI = yes;
          HOTPLUG_PCI_PCIE = yes;
        };
      };
    extraKernelParams =
      lib.optionals verbose [
        "systemd.log_level=info"
        "systemd.log_target=console"
        "systemd.show_status=true"
      ]
      ++ lib.optional stage1Failure "rootfstype=tmpfs";
  };
  inherit (system.config.system.build) image uki;
  disk = "${image}/${system.config.image.fileName}";
  esp = pkgs.runCommand "esp" { } ''
    install -Dm444 ${uki}/${system.config.system.boot.loader.ukiFile} $out/EFI/BOOT/BOOTX64.EFI
  '';
  # The line that ends a boot: its whole text (anchored), and the part the driver can wait for.
  done = if verbose then "Startup finished" else "running";
  doneLine = if verbose then "Startup finished" else "^running$";
  qemu = lib.concatStringsSep " " (
    [
      "${pkgs.qemu_kvm}/bin/qemu-system-x86_64 -machine q35,accel=kvm -cpu host"
      "-m ${toString memory} -smp ${toString cpus} -bios ${pkgs.OVMF.fd}/FV/OVMF.fd"
    ]
    ++ lib.optional (
      format == "onefile" || lateDisk
    ) "-drive if=virtio,format=raw,file=fat:${esp},readonly=on"
    ++ lib.optional (
      format == "image" && !lateDisk
    ) "-drive if=virtio,format=raw,snapshot=on,file=${disk}"
    ++ lib.optionals lateDisk [
      "-drive if=none,id=disk,format=raw,snapshot=on,file=${disk}"
      "-device pcie-root-port,id=late,chassis=1 -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
    ]
  );
in
pkgs.testers.runNixOSTest {
  name = lib.concatStringsSep "-" (
    [ "embedded-boot" ]
    ++ lib.optional stage1Failure "stage1-failure"
    ++ lib.optional lateDisk "late-disk"
    ++ lib.optional (format == "onefile") "onefile"
    ++ lib.optional musl "musl"
    ++ lib.optional (!verbose) "shipped"
    ++ lib.optional (memory != 512 || cpus != 1) "${toString memory}m-${toString cpus}cpu"
  );
  nodes = { };
  testScript = ''
    import re
    from datetime import timedelta

    hang = timedelta(seconds=20)
    # Escape sequences: CSI, and strings (OSC, DCS...) up to their terminator.
    escapes = re.compile(r"\x1b[]P_^X][^\x07\x1b]*(\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")

    def console() -> str:
        return escapes.sub("", machine.get_console_log())

    # The driver matches the lines run together, so the end of a boot is matched here without anchors.
    ended = r"|Kernel panic|emergency mode|degraded"

    machine = create_machine("${qemu}", name="embedded")
    machines_qemu.append(machine)  # so that the driver ends it when a check fails
    machine.start()
    ${
      if stage1Failure then
        ''
          machine.wait_for_console_text("init: the root is neither a ramfs", timeout=hang)
          machine.wait_for_console_text("Kernel panic - not syncing: Attempted to kill init", timeout=hang)
          machine.wait_for_shutdown(timeout=hang)  # panic=-1 reboots, and QEMU (-no-reboot) ends
        ''
      else
        ''
          ${lib.optionalString lateDisk ''
            machine.wait_for_console_text("Waiting for root device PARTLABEL=store" + ended, timeout=hang)
            assert "Waiting for root device" in console()
            machine.send_monitor_command("device_add virtio-blk-pci,drive=disk,bus=late")
          ''}
          machine.wait_for_console_text("${done}" + ended, timeout=hang)
          text = console()
          assert re.search(r"${doneLine}", text, re.M), "no end of startup"
          ${lib.optionalString verbose ''
            assert re.search(r"Reached target .*Multi-User System", text)
            # Not failures: the kernel's command line (it holds systemd.show_status=error), and the host's CPU
            # (-cpu host), an Intel model the kernel's table of latest microcode may not list.
            bad = [
                line for line in text.splitlines()
                if re.search(r"(?i)fail|error|warn|timed out|not found|No such", line)
                and not re.match(r"(Kernel c|C)ommand line: |x86/CPU: Model not found in latest microcode list$", line)
            ]
            assert not bad, "the console shows a failure, error or warning:\n" + "\n".join(bad)
          ''}
          machine.crash()
        ''
    }
  '';
}
