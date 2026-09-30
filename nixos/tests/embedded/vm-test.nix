# The embedded profile's one-file system as a NixOS test VM, booted as it ships: from its own stage 1, with the
# store inside the initrd (rather than NixOS's initrd and the host's store), plus Bash for the test driver; its /etc
# read-only, as the profile makes it, or writable (mutableEtc).
{
  musl,
  mutableEtc ? false,
}:
let
  padding = 8 * 1024 * 1024;
in
{
  name = "embedded${if musl then "-musl" else ""}${if mutableEtc then "-mutable-etc" else ""}";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        ../../modules/profiles/embedded/default.nix
        ../../modules/profiles/embedded/onefile.nix
        (import ./platform.nix { inherit lib musl; })
      ];
      # The test VM's hardware: a disk for udev to describe, and the host's directories (virtiofs).
      embedded.kernelConfig =
        import ../../../pkgs/os-specific/linux/kernel/tiny/qemu.nix { inherit lib; }
        // (with lib.kernel; {
          FUSE_FS = yes;
        });
      virtualisation = {
        # The initrd with the store, and appended to it a file of `padding` bytes, which the system must not
        # keep in memory; its file systems rather than qemu-vm.nix's.
        directBoot.initrd = "${pkgs.buildPackages.runCommand "initrd-padded"
          {
            nativeBuildInputs = [
              pkgs.buildPackages.cpio
              pkgs.buildPackages.xz
            ];
          }
          ''
            mkdir root
            head -c ${toString padding} /dev/zero > root/padding
            cp ${config.system.build.fullInitrd}/initrd $out
            chmod u+w $out
            (cd root && echo padding | cpio --quiet -o -H newc -R +0:+0) | xz --check=crc32 >> $out
          ''
        }";
        mountHostNixStore = false;
        # The system's own file systems (qemu-vm.nix, fileSystems), without the shared directories.
        fileSystems = lib.mkForce { };
        diskImage = null;
        emptyDiskImages = [ 16 ];
        qemu.guestAgent.enable = false; # cross-built, it takes glib, bluez, elfutils and Python
        cores = 3; # the most of the devices this is for
      };

      # What bashless.nix turns off and the test instrumentation needs, and the commands the script runs.
      programs.bash.enable = true;
      environment.shell.enable = true;
      system.forbiddenDependenciesRegexes = lib.mkForce [ ];
      system.etc.overlay.mutable = mutableEtc;
      environment.systemPackages = with pkgs; [
        coreutils
        gnugrep
        findutils
        gnused
        gawk
      ];
      system.extraDependencies = [ "${../../modules/profiles/embedded/check-unit-execs.sh}" ];
      # timesyncd, which test VMs turn off.
      services.timesyncd.enable = lib.mkForce true;

      # A mount unit and a sandboxed service, for libmount and seccomp.
      fileSystems."/mnt/scratch" = {
        device = "tmpfs";
        fsType = "tmpfs";
      };
      systemd.services.sandboxed = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "/run/current-system/sw/bin/sleep infinity";
          SystemCallFilter = [ "@system-service" ];
          ProtectSystem = "strict";
          PrivateTmp = true;
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.machine.system.build)
        toplevel
        storeImage
        etcMetadataImage
        ;
      checkUnits = "bash ${../../modules/profiles/embedded/check-unit-execs.sh} /run/current-system/sw/bin";
    in
    ''
      import os
      mutable_etc = ${if mutableEtc then "True" else "False"}
      from datetime import timedelta

      # The system, as the UKI's command line names it.
      os.environ["QEMU_KERNEL_PARAMS"] = "NIXOS_SYSTEM=${toplevel}"
      machine.wait_for_unit("multi-user.target")

      with subtest("PID 1 is the static multicall systemd, on three CPUs, and the system is running"):
          assert machine.succeed("readlink -f /proc/1/exe").strip().endswith("/lib/systemd/systemd-multicall")
          machine.fail("grep -q '\\.so' /proc/1/maps")
          assert machine.succeed("cat /sys/devices/system/cpu/online").strip() == "0-2"
          state = machine.succeed("systemctl is-system-running --wait || true").strip()
          assert state == "running", machine.succeed("systemctl list-units --failed --plain --no-legend")

      with subtest("every unit's program exists, and no unit or configuration link dangles"):
          machine.succeed("${checkUnits} /etc/systemd/system/ /etc/systemd/user/")
          machine.succeed("DANGLING=0 ${checkUnits} $(ls -d /run/systemd/generator*/)")
          for line in machine.succeed("systemctl list-units --all --plain --no-legend --state=not-found").splitlines():
              unit = line.split()[0]
              assert machine.succeed(f"systemctl show --value -p RequiredBy,BoundBy {unit}").split() == [], unit
          machine.succeed("find -L /etc/tmpfiles.d/ /etc/systemd/ /etc/udev/ -type l > /tmp/dangling")
          machine.succeed("test ! -s /tmp/dangling || { cat /tmp/dangling; false; }")

      with subtest("the store is the initramfs's image, without a loop device, and the rest of the initramfs is gone"):
          machine.succeed("grep -q '^/store.erofs /nix/store erofs ro,' /proc/mounts")
          machine.succeed("grep -q '^overlay /etc overlay ${
            if mutableEtc then "rw" else "ro"
          },' /proc/mounts")
          machine.fail("test -e /sys/block/loop0")
          # A ramfs's pages are unevictable: only the two images the mounts hold may stay.
          images = os.path.getsize("${storeImage}") + os.path.getsize("${etcMetadataImage}")
          unevictable = int(machine.succeed("awk '/^Unevictable:/ {print $2}' /proc/meminfo")) * 1024
          assert images <= unevictable < images + ${toString padding}, f"{unevictable} unevictable, {images} of images"

      # A writable /etc, new at every boot with an empty machine-id, makes every boot a first boot.
      with subtest("the journal: no failed renames (musl's cached TID); a first boot only with a writable /etc"):
          journal = machine.succeed("journalctl -b --no-pager -o cat")
          assert "Reached target" in journal and "Failed to rename process" not in journal
          assert ("Detected first boot" in journal) == mutable_etc
          machine.succeed("grep -qE '^[0-9a-f]{32}$' /etc/machine-id")

      if mutable_etc:
          with subtest("/etc is writable, through onefile-init.c's upper directory"):
              machine.succeed("echo written > /etc/embedded-test")
              machine.succeed("grep -qx written /.rw-etc/upper/embedded-test")

      with subtest("the kernel's log holds the boot until journald reads it, and every sysctl has its knob"):
          machine.succeed("journalctl -k -b --no-pager -o cat | grep -q '^Linux version '")
          assert "Couldn't write" not in machine.succeed("journalctl -b --no-pager -o cat -u systemd-sysctl.service")
          # For the sizes of the kernel's log and hash tables (the profile's kernel parameters).
          print(machine.succeed("journalctl -k -b -o cat | grep -E '^(Dentry cache|Inode-cache) hash table entries'"))
          print(machine.succeed("cat /proc/sys/fs/dentry-state /proc/sys/fs/inode-nr"))

      with subtest("udev, mount units, seccomp, PID 1's private socket, networkd, resolved, timesyncd, oomd"):
          machine.succeed("udevadm info /dev/vda | grep -q DEVNAME")
          machine.succeed("systemctl is-active mnt-scratch.mount")
          machine.wait_for_unit("sandboxed.service")
          machine.succeed("grep -q '^Seccomp:\\s*2$' /proc/$(systemctl show -P MainPID sandboxed.service)/status")
          machine.succeed("systemd-run --no-block --unit=probe touch /run/probe")
          machine.wait_until_succeeds("test -e /run/probe")
          for unit in ["systemd-networkd", "systemd-resolved", "systemd-timesyncd", "systemd-oomd"]:
              machine.wait_for_unit(f"{unit}.service")
          machine.succeed("networkctl status && resolvectl status")

      # machine.reboot() fails in this test driver (virtiofsd exits when the guest restarts, with stock systemd
      # too: ./reboot-control.nix); a power-off takes the same path through systemd-shutdown.
      with subtest("power off goes through systemd-shutdown, and the system boots again"):
          first_boot = machine.succeed("cat /proc/sys/kernel/random/boot_id")
          machine.shutdown()
          # Without systemd-shutdown, PID 1 would power off with reboot(2) itself.
          machine.wait_for_console_text(r"systemd-shutdown\[1\]: ", timeout=timedelta(seconds=10))
          machine.start()
          machine.wait_for_unit("multi-user.target")
          assert machine.succeed("cat /proc/sys/kernel/random/boot_id") != first_boot
          machine.shutdown()
    '';
}
