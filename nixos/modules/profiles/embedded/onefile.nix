# A UKI holding the whole system: the store is an EROFS image in the initrd, mounted where the kernel unpacked
# it, and / is a tmpfs. There is no NixOS stage 1: ./onefile-init.c makes the mounts and starts systemd.
# NixOS's initrd (system.build.initialRamdisk) is that program alone, which names no system; the store is
# appended to it as a second archive, and the UKI's command line names the system (NIXOS_SYSTEM=).
#
# With embedded.storePartition (./image.nix), the kernel mounts the same image from that partition instead, and
# the UKI has no initrd.
{
  config,
  options,
  lib,
  pkgs,
  staticPkgs,
  ...
}:
let
  inherit (pkgs) buildPackages;
  inherit (config.system.build) toplevel;
  kernel = config.boot.kernelPackages.kernel;
  initrd = config.system.build.initialRamdisk;
  partition = config.embedded.storePartition;

  # NixOS's etc overlay, as its systemd initrd mounts it (etc-activation.nix): mount flags, and data with the
  # system's path left to ./onefile-init.c.
  etcOverlay =
    let
      mount =
        lib.findSingle (m: m.where == "/sysroot/etc") (throw "no /sysroot/etc mount")
          (throw "several /sysroot/etc mounts")
          config.boot.initrd.systemd.mounts;
      flags = {
        nodev = "MS_NODEV";
        nosuid = "MS_NOSUID";
        relatime = "MS_RELATIME";
        ro = "MS_RDONLY";
        rw = "0";
      };
      mountOptions = lib.splitString "," (
        builtins.replaceStrings [ "=/sysroot/" ] [ "=/" ] mount.options
      );
      data = lib.filter (option: !flags ? ${option}) mountOptions;
      known = [
        "redirect_dir="
        "metacopy="
        "lowerdir="
        "upperdir="
        "workdir="
      ];
    in
    assert lib.assertMsg (lib.all (
      o: lib.any (p: lib.hasPrefix p o) known
    ) data) "unknown options of NixOS's /etc overlay: ${mount.options}";
    {
      flags = lib.concatMapStringsSep "|" (o: flags.${o}) (lib.filter (o: flags ? ${o}) mountOptions);
      # A format for onefile-init.c, whose compiler checks that it takes the system's path once.
      data = builtins.replaceStrings [ "%" "/etc-basedir" ] [ "%%" "%s/etc-basedir" ] (
        lib.concatStringsSep "," data
      );
    };

  cString = s: if s == null then "NULL" else builtins.toJSON s;
  defines = {
    ETC_MUTABLE = if config.system.etc.overlay.mutable then 1 else 0;
    ETC_FLAGS = "(${etcOverlay.flags})";
    ETC_DATA = builtins.toJSON etcOverlay.data;
    ENV_BINARY = cString config.environment.usrbinenv;
    SH_BINARY = cString config.environment.binsh;
  };
  init = staticPkgs.runCommandCC "onefile-init" { } ''
    $CC -Oz -s -static -Wall -Wextra -Werror -o $out ${./onefile-init.c} ${
      lib.concatMapAttrsStringSep " " (
        name: value: lib.escapeShellArg "-D${name}=${toString value}"
      ) defines
    }
  '';

  # nixpkgs' initrd builder, compressed as NixOS's systemd initrds are (xz's default arguments). It puts a path
  # under /nix/store and links it from `target`.
  stage1 = pkgs.makeInitrdNG {
    name = "initrd-onefile";
    compressor = "xz";
    contents = [
      {
        source = init;
        target = "/init";
      }
    ];
  };

  # The system's closure (with the init for a partition: the kernel parameters name it), as a root file system,
  # without the kernel and the initrd, which the UKI carries.
  storeImage =
    buildPackages.runCommand "embedded-store.erofs"
      {
        nativeBuildInputs = [
          buildPackages.erofs-utils
          buildPackages.util-linux # hardlink
        ];
        closure = buildPackages.closureInfo {
          rootPaths = [ toplevel ];
        };
        excluded = [
          kernel
          (lib.getOutput "modules" kernel)
          config.system.modulesTree
          initrd
        ];
      }
      ''
        mkdir -p root/nix/store root/sysroot
        printf '%s\n' $excluded > excluded
        grep -v -x -F -f excluded $closure/store-paths | xargs cp -a --target-directory=root/nix/store
        chmod -R u+w root
        # What no program reads at run time.
        shopt -s nullglob
        for dir in root/nix/store/*/share/{man,info,doc,bash-completion,zsh,fish,dbus-1/interfaces}; do
          rm -r "$dir"
        done
        hardlink --quiet root
        # The LZMA dictionary is set, not left at 4 times the cluster: the kernel keeps all of it in memory. The
        # clusters are as large: larger ones compress better, and a smaller dictionary would not span one.
        mkfs.erofs -zlzma,dictsize=524288 -C524288 -Efragments -U 00000000-0000-0000-0000-000000000000 \
          --ignore-mtime --force-uid=0 --force-gid=0 $out root
      '';

  # The store, and a copy of the etc metadata image (EROFS mounts no image file from an EROFS mounted from one),
  # after the init, as netboot.nix appends its store to NixOS's initrd.
  fullInitrd = pkgs.makeInitrdNG {
    name = "embedded-initrd";
    compressor = "xz";
    prepend = [ "${initrd}/${config.system.boot.loader.initrdFile}" ];
    contents = [
      {
        source = storeImage;
        target = "/store.erofs";
      }
      {
        source = config.system.build.etcMetadataImage;
        target = "/etc-metadata-image";
      }
    ];
  };
in
{
  options.embedded.storePartition = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "The GPT label of the partition holding the store, or null for a store in the initrd.";
  };

  config = {
    assertions = [
      {
        # onefile-init.c mounts /etc as the etc overlay does, and replaces nixos-init (which the system does not
        # run): with nixos-init enabled, the toplevel has no Bash stage 2 (prepare-root).
        assertion = config.system.etc.overlay.enable && config.system.nixos-init.enable;
        message = "the embedded profile needs system.etc.overlay.enable and system.nixos-init.enable";
      }
      {
        # (The option's value is a buildEnv, never empty.)
        assertion =
          lib.concatLists options.hardware.firmware.definitions == [ ]
          && config.boot.initrd.luks.devices == { };
        message = "the embedded profile's stage 1 loads no firmware and unlocks no LUKS device";
      }
    ];
    warnings = lib.optional (
      config.specialisation != { }
    ) "the embedded profile boots only the system itself, not its specialisations";
    # No root= for the initrd's systemd, which the system does not run: the layouts set their own.
    boot.initrd.systemd.root = null;
    # /var is in memory too: the journal only in /run, rather than also in /var/log.
    services.journald.settings.Journal.Storage = lib.mkDefault "volatile";

    boot.kernelParams =
      if partition == null then
        [ "rootfstype=ramfs" ]
      else
        [
          "root=PARTLABEL=${partition}"
          "rootfstype=erofs"
          "rootwait"
          "init=${init}"
        ];
    embedded.kernelConfig = import ../../../../pkgs/os-specific/linux/kernel/tiny/uefi.nix {
      inherit lib;
    };

    system.build.initialRamdisk = lib.mkForce stage1;
    system.systemBuilderCommands = ''
      ln -s ${config.system.build.etcMetadataImage} $out/etc-metadata-image
      ln -s ${config.system.build.etcBasedir} $out/etc-basedir
    '';
    # The file systems ./onefile-init.c mounts.
    fileSystems = {
      "/" = {
        fsType = "tmpfs";
        options = [ "mode=0755" ];
      };
      "/nix/store" = {
        device = if partition == null then "/store.erofs" else "/dev/disk/by-partlabel/${partition}";
        fsType = "erofs";
        options = [
          "ro"
          "nodev"
          "nosuid"
        ];
      };
    };

    boot.uki.settings.UKI = {
      Cmdline = "NIXOS_SYSTEM=${toplevel} ${toString config.boot.kernelParams}";
      Initrd = if partition == null then "${fullInitrd}/initrd" else null;
      # The static systemd has no boot loader parts; the stub is only copied into the UKI.
      Stub = "${buildPackages.systemdUkify}/lib/systemd/boot/efi/linux${pkgs.stdenv.hostPlatform.efiArch}.efi.stub";
    };

    system.build = {
      inherit
        init
        storeImage
        fullInitrd
        ;
    };
  };
}
