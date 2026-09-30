# NixOS for devices with little storage and memory (256-512 MiB, fewer than four cores), as MixOS
# (github:jmbaur/mixos) builds its systems, but with NixOS and systemd: the appliance profiles (no Nix, no
# switching, no Perl, no Bash, no logins), a kernel with only what the system and its hardware need, and a
# static multicall systemd. Import it with ./onefile.nix or ./image.nix.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  inherit (lib)
    mkDefault
    mkForce
    mkOption
    types
    ;
  inherit (config.boot.kernelPackages) kernel;
  # The kernel's configuration as asked for: with ignoreConfigErrors off, it is also what the kernel has.
  tristate = option: kernel.structuredExtraConfig.${option}.tristate or null;
  kernelHas = option: tristate option == "y";

  # One static musl package set, built for size (-Oz), for systemd and for ./onefile-init.c: pkgsStatic's
  # platform, with the vendor fixed so that glibc and musl systems share it.
  staticPkgs = import pkgs.path {
    localSystem = pkgs.stdenv.buildPlatform;
    crossSystem = {
      config = lib.systems.parse.tripleFromSystem (
        lib.systems.parse.mkMuslSystem (
          pkgs.stdenv.hostPlatform.parsed // { vendor = lib.systems.parse.vendors.unknown; }
        )
      );
      isStatic = true;
      gcc = pkgs.stdenv.hostPlatform.gcc or { };
    };
    crossOverlays = [ (import ../../../../pkgs/os-specific/linux/systemd/multicall/size-overlay.nix) ];
    config.allowUnsupportedSystem = true;
  };

  # Units run programs by absolute path, and have no scripts: none needs NixOS's default PATH.
  withoutDefaultPath = mkOption {
    type = types.attrsOf (types.submodule { config.enableDefaultPath = mkDefault false; });
  };
in
{
  imports = [
    "${modulesPath}/profiles/image-based-appliance.nix"
    "${modulesPath}/profiles/bashless.nix"
  ];

  options.systemd.services = withoutDefaultPath;
  options.systemd.user.services = withoutDefaultPath;
  # System users' shell: util-linux's nologin, which systemd has, rather than shadow's, which brings PAM. Above
  # the option's default, below the mkDefault users-groups.nix gives root and normal users.
  options.users.users = mkOption {
    type = types.attrsOf (
      types.submodule {
        config.shell = lib.mkOverride 1400 "${config.systemd.package.util-linux.login}/bin/nologin";
      }
    );
  };

  options.embedded.kernelConfig = mkOption {
    # The kernel builder's own type (structuredExtraConfig), which merges equal and `option` definitions.
    inherit ((lib.evalModules { modules = [ ../../system/boot/kernel_config.nix ]; }).options.settings)
      type
      ;
    default = { };
    example = lib.literalExpression "{ VIRTIO_BLK = lib.kernel.yes; }";
    description = "Kconfig options of the hardware (lib.kernel values), built into the kernel.";
  };

  config = {
    systemd.package = mkDefault (
      staticPkgs.callPackage ../../../../pkgs/os-specific/linux/systemd/multicall/default.nix {
        systemd = staticPkgs.systemdMinimal.override {
          withKmod = false;
          withLibseccomp = true;
          withNetworkd = true;
          withOomd = true;
          withResolved = true;
          withSysusers = true;
          withTimesyncd = true;
        };
        mesonOptions = {
          translations = "false";
          libcrypt = "disabled"; # for plain-text passwords given to sysusers
          smack = "false";
        };
        # The programs of the units NixOS installs for these features. udev's helpers come regardless.
        programs = [
          "systemd"
          "systemd-shutdown"
          "systemctl"
          "systemd-journald"
          "journalctl"
          "udevadm"
          "systemd-tmpfiles"
          "systemd-sysctl"
          "systemd-sysusers"
          "systemd-fsck"
          "systemd-remount-fs"
          "systemd-fstab-generator"
          "systemd-debug-generator"
          "systemd-factory-reset-generator"
          "systemd-run"
          "systemd-machine-id-setup"
          "systemd-random-seed"
          "systemd-update-done"
          "systemd-backlight"
          "systemd-rfkill"
          "systemd-growfs"
          "systemd-makefs"
          "systemd-pstore"
          "systemd-sleep"
          "systemd-mute-console"
          "systemd-creds"
          "systemd-ask-password"
          "systemd-tty-ask-password-agent"
          "systemd-sulogin-shell"
          "systemd-factory-reset"
          "systemd-timesyncd"
          "systemd-oomd"
          "systemd-networkd"
          "systemd-networkd-wait-online"
          "networkctl"
          "systemd-resolved"
          "resolvectl"
        ];
      }
    );
    systemd.sysusers.enable = mkDefault true;
    services.userborn.enable = false; # the perlless profile's; sysusers instead
    # Only logind needs a bus, which systemd.nix turns on regardless.
    services.dbus.enable = lib.mkIf (!config.services.logind.enable) (mkForce false);
    systemd.coredump.enable = mkDefault false;

    boot.kernelPackages = pkgs.linuxPackagesFor (
      import ../../../../pkgs/os-specific/linux/kernel/tiny/default.nix {
        inherit lib;
        linux = pkgs.linux_latest;
        # What NixOS's modules require (system.requiredKernelConfig, each entry with its configLine) wins.
        config =
          import ../../../../pkgs/os-specific/linux/kernel/tiny/nixos.nix { inherit lib; }
          // config.embedded.kernelConfig
          // lib.listToAttrs (
            map (
              required:
              let
                line = builtins.match "CONFIG_([A-Za-z0-9_]+)=([ymn])" required.configLine;
              in
              lib.nameValuePair (lib.elemAt line 0) (
                {
                  y = lib.kernel.yes;
                  m = lib.kernel.module;
                  n = lib.kernel.no;
                }
                .${lib.elemAt line 1}
              )
            ) config.system.requiredKernelConfig
          );
      }
    );
    assertions = [
      {
        # onefile-init.c moves out of the initramfs.
        assertion = lib.versionAtLeast kernel.version "7.0";
        message = "the embedded profile needs Linux 7.0 or later";
      }
    ];
    _module.args.staticPkgs = staticPkgs;
    system.checks = [
      # The multicall systemd has only the listed programs: every unit's must be among them.
      (pkgs.buildPackages.runCommand "unit-programs" { } ''
        OUTSIDE_STORE=0 bash ${./check-unit-execs.sh} ${config.system.path}/bin \
          ${config.system.build.etc}/etc/systemd/system/ ${config.system.build.etc}/etc/systemd/user/
        touch $out
      '')
    ];

    # udev's own helpers, rather than NixOS's util-linux, coreutils, sed and grep.
    services.udev.path = mkForce [ config.systemd.package ];
    # A read-only /etc: with an empty machine-id, systemd gives each boot a transient one, and no boot is a
    # first boot (presets, the journal catalog) as on a writable /etc new at every boot.
    system.etc.overlay.mutable = mkDefault false;
    services.getty.enable = mkDefault false;
    security.shadow.enable = mkDefault false;
    security.pam.enable = mkDefault false;
    boot.modprobeConfig.enable = mkDefault false; # every driver is built in
    # So modprobe@ never runs (there is no modprobe); skipped, it still satisfies the mounts that require it.
    systemd.services."modprobe@".unitConfig.ConditionPathExists = lib.mkIf (
      !config.boot.modprobeConfig.enable
    ) "!/";
    systemd.services."modprobe@".serviceConfig.ExecSearchPath = mkForce "/run/current-system/sw/bin";
    # Units NixOS configures that a systemd without kmod and PAM does not install.
    systemd.suppressedSystemUnits = [
      "systemd-modules-load.service"
      "kmod-static-nodes.service"
      "systemd-user-sessions.service"
    ];
    # systemd-hwdb writes a database only from a file with something in it; this systemd ships none.
    services.udev.extraHwdb = "# no entries";
    # boot.json names kmod for nixos-init, which this system does not run.
    boot.bootspec.extensions."org.nixos.nixos-init.v1".modprobe_binary = mkForce null;
    environment.usrbinenv = mkDefault null;
    # systemd-update-done records /usr's modification time, and fails without /usr.
    systemd.services.systemd-update-done.unitConfig.ConditionPathExists = lib.mkIf (
      config.environment.usrbinenv == null
    ) "/usr";
    boot.kernelParams = [
      # The serial console's type and size, which systemd would otherwise query, waiting 333 ms per answer.
      "systemd.tty.term.console=vt220"
      "systemd.tty.rows.console=24"
      "systemd.tty.columns.console=80"
      "panic=-1" # reboot at once: no one reads the console
      "systemd.show_status=error"
      # Hash tables of the next power of two above the dentries and inodes in use (about 7,900 and 7,300),
      # rather than sized to the memory.
      "dhash_entries=8192"
      "ihash_entries=8192"
    ];
    systemd.settings.Manager.CrashAction = mkDefault "reboot";
    # BASE_SMALL allows at most PAGE_SIZE * 8 processes; NixOS asks for 4194304.
    boot.kernel.sysctl."kernel.pid_max" = lib.mkIf (kernelHas "BASE_SMALL") (
      if pkgs.stdenv.hostPlatform.isx86 then
        4096 * 8
      else
        throw "the embedded profile: the page size of ${pkgs.stdenv.hostPlatform.system}'s kernel, for kernel.pid_max"
    );
    security.lsm = lib.mkIf (!kernelHas "SECURITY") (mkForce [ ]);
    # Settings of knobs the kernel may lack (MAGIC_SYSRQ, COREDUMP), which systemd-sysctl would warn about at
    # every boot: with "-" it skips them quietly. null drops a setting of NixOS's (sysctl.nix); the last is the
    # test instrumentation's.
    environment.etc."sysctl.d/50-default.conf".source = mkForce (
      pkgs.runCommand "50-default.conf" { } ''
        sed -E 's/^kernel\.(sysrq|core_uses_pid) /-&/' ${config.systemd.package}/example/sysctl.d/50-default.conf > $out
      ''
    );
    boot.kernel.sysctl."kernel.core_pattern" = lib.mkIf (!kernelHas "COREDUMP") null;
    boot.kernel.sysctl."kernel.hung_task_timeout_secs" = lib.mkIf (!kernelHas "DETECT_HUNG_TASK") (
      mkForce null
    );
    # / is a tmpfs over a read-only store: nothing to unmount carefully, check, trim or format.
    systemd.shutdownRamfs.enable = mkDefault false;
    system.fsPackages = mkForce [ ];
    services.fstrim.enable = mkDefault false;
    services.lvm.enable = mkDefault false;
    # nixos-init's environment generator: the only reference to nixos-init (and so to a libc) in the system.
    # Generators' PATH (systemd.generatorPath) would hold only systemd's own util-linux, and no fsck.
    environment.etc."systemd/system-environment-generators/env-generator".enable = mkDefault false;
    # The static systemd has no NSS modules, and nothing else uses nscd.
    system.nssModules = mkForce [ ];
    services.nscd.enable = mkDefault false;

    # Time zones: UTC and the configured one, rather than all of tzdata.
    environment.etc.zoneinfo.source = mkForce (
      pkgs.runCommand "zoneinfo" { } ''
        mkdir $out
        for zone in UTC ${lib.optionalString (config.time.timeZone != null) config.time.timeZone}; do
          install -D -m 0444 ${pkgs.buildPackages.tzdata}/share/zoneinfo/$zone $out/$zone
        done
      ''
    );
    systemd.globalEnvironment.TZDIR = mkForce "/etc/zoneinfo";
    # Copies rather than links into glibc and iana-etc; no /etc/services, which nothing looks up.
    environment.etc.rpc = lib.mkIf (pkgs.stdenv.hostPlatform.libc == "glibc") {
      source = mkForce (pkgs.runCommand "rpc" { } "cp ${pkgs.stdenv.cc.libc.out}/etc/rpc $out");
    };
    environment.etc.services.enable = mkDefault false;
    environment.etc.protocols.source = mkForce (
      pkgs.runCommand "protocols" { } "cp ${pkgs.iana-etc}/etc/protocols $out"
    );
    security.pki.installCACerts = mkDefault false;
    i18n.defaultLocale = mkDefault "C.UTF-8";
    i18n.glibcLocales = mkDefault null;
    security.sudo.enable = mkDefault false;
    programs.nano.enable = mkDefault false;
    programs.less.enable = mkForce false; # environment.nix sets it without a priority
    fonts.fontconfig.enable = mkDefault false;

    # Cross-compiled only (natively it would rebuild build tools as well): util-linux is a build input of udev's
    # rules and mdadm, and lastlog2's sqlite (a build input regardless) fails its tests when the build machine
    # runs them.
    nixpkgs.overlays = [
      (final: prev: {
        util-linux =
          if lib.systems.equals final.stdenv.hostPlatform final.stdenv.buildPlatform then
            prev.util-linux
          else
            prev.util-linux.override {
              withLastlog = false;
              sqlite = null;
            };
      })
    ];
  };
}
