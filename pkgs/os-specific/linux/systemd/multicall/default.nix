# systemd 262 with the programs chosen linked into one static binary, lib/systemd/systemd-multicall, each
# installed as a symlink to it (./patches: -Dmulticall-binary). Units, rules and configuration are installed as
# usual, so the result can be NixOS's systemd.package. Features are nixpkgs' switches, which NixOS also reads:
#   callPackage ./. { systemd = systemdMinimal.override { withNetworkd = true; }; programs = [ ... ]; }
# Build it in a static package set, ideally with ./size-overlay.nix.
{
  lib,
  stdenv,
  writeText,
  fetchFromGitHub,
  coreutils,
  systemd,
  util-linuxMinimal,
  # The programs to link in (null: all the features build); the others are not installed. udev's rule helpers
  # are linked in regardless.
  programs ? null,
  # Meson options that replace nixpkgs' value.
  mesonOptions ? { },
  # util-linux's programs besides its libraries: those systemd runs (mount-path, sulogin-path, nologin-path).
  utilLinuxPrograms ? [
    "mount"
    "sulogin"
    "nologin"
  ],
}:
let
  # What cannot be built static: linux-pam, p11-kit, elfutils, libpwquality, and what needs them.
  systemd' = systemd.override {
    withPam = false;
    withHomed = false;
    withLibBPF = false;
    withPasswordQuality = false;
    withFido2 = false;
    p11-kit = null;
    libfido2 = null;
    elfutils = null;
    util-linux = util-linux';
  };

  # The libraries systemd links, and utilLinuxPrograms: static, every other program would carry its own copy.
  util-linux' = util-linuxMinimal.overrideAttrs (old: {
    configureFlags =
      old.configureFlags
      ++ [
        "--disable-all-programs"
        "--enable-libuuid"
        "--enable-libblkid"
        "--enable-libmount"
        "--enable-libfdisk"
        "--enable-libsmartcols"
        "--disable-write" # nixpkgs enables it, and --disable-all-programs does not undo that
      ]
      ++ map (program: "--enable-${program}") utilLinuxPrograms;
    # Links to the programs left out; the outputs of those (swap) stay empty.
    postInstall = old.postInstall + ''
      for output in $(getAllOutputNames); do
        mkdir -p "''${!output}"
        find "''${!output}" -xtype l -delete
      done
    '';
  });

  mesonOptions' = {
    build-static = "true";
    systemd-multicall-binary = "true";
    multicall-binary = "true";
    multicall-programs = lib.concatStringsSep "," (if programs == null then [ ] else programs);
    # No switch in the expression: p11-kit follows cryptsetup, elfutils coredump.
    p11kit = "disabled";
    elfutils = "disabled";
    # libcryptsetup loads token plugins with dlopen(); systemd-cryptsetup unlocks TPM2 and FIDO2 tokens itself.
    libcryptsetup-plugins = "disabled";
    man = "disabled";
  }
  // mesonOptions;
in
systemd'.overrideAttrs (
  finalAttrs: old: {
    pname = "systemd-multicall";
    version = "262";

    src = fetchFromGitHub {
      owner = "systemd";
      repo = "systemd";
      tag = "v${finalAttrs.version}";
      hash = "sha256-oGzFW2dD8abLXBwDczr1hvl712s03CHTUqOz6uPfhmQ=";
    };

    # Half of the zoneinfo patch no longer applies to 262; until it is rebased, time zones are in
    # /usr/share/zoneinfo.
    patches =
      builtins.filter (
        p: !lib.hasInfix "Change-usr-share-zoneinfo-to-etc-zoneinfo" (toString p)
      ) old.patches
      ++ [
        ./patches/0001-meson-link-the-libraries-systemd-dlopen-s-into-stati.patch
        ./patches/0002-dlfcn-util-bind-dlopen-wrappers-to-linked-in-symbols.patch
        ./patches/0003-musl-implement-gettid-raise-and-abort-with-system-ca.patch
        ./patches/0004-meson-optionally-link-the-installed-programs-into-on.patch
      ];

    # The symbol table too (the debug output keeps it): without elfutils, systemd does not symbolize backtraces.
    stripAllList = (old.stripAllList or [ ]) ++ [ "lib/systemd" ];

    mesonFlags =
      builtins.filter (
        f: !lib.any (o: lib.hasPrefix "-D${o}=" f) (lib.attrNames mesonOptions')
      ) old.mesonFlags
      ++ lib.mapAttrsToList lib.mesonOption mesonOptions';

    env = old.env // {
      # Rather than pkgsStatic's -static, which would reach the shared libraries too. The notes naming the
      # dlopen() libraries, which are linked in, are discarded: tools reading them (make-initrd-ng) would look for
      # the libraries. (objcopy would drop PT_GNU_RELRO with them.)
      NIX_CFLAGS_LINK = "-Wl,-T,${writeText "discard-dlopen-notes.ld" ''
        SECTIONS { /DISCARD/ : { *(.note.dlopen) } } INSERT AFTER .text;
      ''}";
      # No unwind tables: nothing unwinds (no exceptions, no backtrace()); debuggers use the debug output's
      # .debug_frame.
      NIX_CFLAGS_COMPILE = toString [
        old.env.NIX_CFLAGS_COMPILE
        "-fno-asynchronous-unwind-tables"
        "-fno-unwind-tables"
      ];
    };

    postInstall = old.postInstall + ''
      # No static program uses the shared libraries or NSS modules, and auto-patchelf could not resolve them.
      find $out -name '*.so' -delete -o -name '*.so.*' -delete
      find $out -xtype l -delete
      # The journal's message catalogs in English only; journalctl -x shows others only in their locale.
      find $out/lib/systemd/catalog -name '*.*.catalog' -delete
      # The D-Bus services' Exec= is never run (the broker activates them through systemd): a path outside
      # the store keeps the static coreutils out of the closure.
      substituteInPlace $out/share/dbus-1/system-services/*.service \
        --replace-fail ${coreutils}/bin/false /run/current-system/sw/bin/false
      mkdir -p "$man" # no manual pages are built
      # Static (run on every platform: the install check runs only where the build machine can execute it).
      elf=$(${stdenv.cc.targetPrefix}readelf -l $out/lib/systemd/systemd-multicall)
      [[ $elf != *INTERP* ]] || { echo "systemd-multicall is dynamically linked" >&2; exit 1; }
    '';

    # Every link to the binary names one of its programs, whether run by path or by name: the link chain
    # (poweroff -> systemctl -> systemd-multicall) is followed only for a path. (The dispatcher exits 127, so
    # its output is captured rather than piped.) A program need not end: systemd-sulogin-shell ignores
    # --version and retries forever. timeout ends such a one; the dispatcher rejects an unknown name before
    # any program runs, with one line.
    postInstallCheck = ''
      unknown=0 probed=0
      while IFS= read -r -d "" p; do
        [[ $(readlink -f "$p") == $out/lib/systemd/systemd-multicall ]] || continue
        for argv0 in "$p" "''${p##*/}"; do
          status=0
          output=$(timeout 10 bash -c 'exec -a "$1" "$2" --version' _ "$argv0" \
            $out/lib/systemd/systemd-multicall </dev/null 2>&1) || status=$?
          if [ $status = 124 ]; then echo "$argv0 did not end; stopped" >&2; fi
          probed=$((probed + 1))
          if [[ $output == *"not a program of this multicall binary"* ]]; then
            echo "the multicall binary does not recognize $argv0" >&2
            unknown=1
          fi
        done
      done < <(find $out -type l -print0)
      [ $unknown = 0 ] && [ $probed -gt 0 ]
    '';

    # A static package set propagates build inputs for static-library consumers; there are none (the shared
    # libraries are gone), and the dev output would refer to bash-static, which nixpkgs disallows.
    postFixup = ''
      for output in $(getAllOutputNames); do
        rm -f "''${!output}/nix-support/propagated-build-inputs"
        if [ -d "''${!output}/nix-support" ]; then rmdir --ignore-fail-on-non-empty "''${!output}/nix-support"; fi
      done
    '';

    meta = old.meta // {
      description = "systemd with its programs in one statically linked multicall binary";
      # systemd marks static builds as bad; this one is static by design.
      badPlatforms = [ ];
      maintainers = [ lib.maintainers.connorbaker ];
      teams = [ ];
    };
  }
)
