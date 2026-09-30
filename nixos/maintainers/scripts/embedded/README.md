## Embedded NixOS: a static multicall systemd, a tinyconfig kernel, and a one-file UKI

This PR adds a NixOS profile for devices with little storage and memory (256–512 MiB of RAM, fewer than four
cores), in the spirit of [MixOS](https://github.com/jmbaur/mixos), but keeping NixOS and systemd. The firmware
boots one UKI that goes straight to systemd: no NixOS stage 1, no second systemd in an initrd, no Bash, no Perl,
no dynamic linking, no kernel module support.

### Results

x86_64, Linux 7.2.8, QEMU q35 with OVMF, the musl system. MixOS is its own reference configuration at
v1.13.0-3-g5ffa230, built on a kernel from the same builder (`pkgs/os-specific/linux/kernel/tiny`) with the
same hardware options, and module support, which its initrd builder needs.

| | MixOS | this PR, one-file UKI | this PR, disk image |
|---|--:|--:|--:|
| what the firmware loads | 16,035,840 B | 6,056,448 B | 2,630,144 B (UKI, no initrd) |
| kernel (`.linux`) | 1,807,360 B | 2,454,528 B | 2,454,528 B |
| initrd (`.initrd`) | 14,052,628 B | 3,426,084 B (init + store) | none |
| whole disk image | — | | 7,266,816 B (ESP 2,646,016 + store 3,555,328) |
| store image (EROFS) | — | 3,555,328 B | same image, as a partition |
| system closure | — | 120 paths, 23.2 MB, no libc | same |
| startup, guest clock (verbose boot) | — | 0.53–0.54 s (kernel 0.23–0.24 s) | 0.52 s (kernel 0.22–0.23 s) |
| startup, guest clock (as shipped) | — | 0.42–0.47 s | |
| MemAvailable 30 s after boot (as shipped) | — | 207,908 kB at 256 MiB with 3 CPUs; 462,961 kB at 512 MiB with 1 CPU | the same system |

The glibc and musl systems are the same size to within a few KB: every program is static, so neither libc
is in the closure.

Memory is the mean, and the shipped startup the range, of three boots of the one-file UKI at each size, with
a diagnostic unit that prints /proc/meminfo 30 s after boot. MixOS's memory and startup weren't measured on this build.

The kernel is bigger than MixOS's because of what systemd and NixOS need: cgroups, namespaces, seccomp,
BPF, IPv6, autofs and so on. Most of the store image is systemd's binary (8,468,544 B uncompressed).

### How it gets there

#### 1. systemd as one static binary (`pkgs/os-specific/linux/systemd/multicall`)

systemd 262 with the chosen programs linked into one static binary, `lib/systemd/systemd-multicall`. Each
program is installed as a symlink to it. Units, rules and configuration install as usual, so the package can
be NixOS's `systemd.package`. Features are nixpkgs' own `systemd` switches, which the NixOS modules already
read; the profile starts from `systemdMinimal` and adds networkd, resolved, timesyncd, oomd, sysusers and
seccomp, with 37 programs.

Four patches, meant to go upstream:

1. meson: link the libraries systemd `dlopen()`s into static builds.
2. dlfcn-util: bind the `dlopen()` wrappers to the linked-in symbols.
3. musl: `gettid()`, `raise()` and `abort()` by system call. musl caches the thread ID, which a
   `raw_clone()` child inherits: its `raise()` signalled the parent and `abort()` crashed the child with
   SIGSEGV. This covers every `raise()` and `abort()` systemd itself calls, including assertions.
4. meson: optionally link the installed programs into one binary (`-Dmulticall-binary`). Each program's
   objects are partially linked into one, whose options, verbs and static destructors move to sections of
   the program's own: otherwise the linker-defined `__start_`/`__stop_` symbols would span every program's.

Size work: the dependencies come from a static package set built with `-Oz` and fat LTO objects, which the
final link LTO-links through the linker plugin. There are no unwind tables (nothing unwinds; the debug output
keeps `.debug_frame`), only English journal catalogs, and the `.note.dlopen` sections are discarded at link
time (their libraries are linked in). Not built: what can't be static (PAM, homed, libbpf, pwquality, FIDO2,
p11-kit, elfutils). `postInstallCheck` runs every installed link, by path and by name, and fails if the
binary doesn't recognize it.

Binary 8,468,544 B; package closure 10,288,488 B, including util-linux's libraries and `mount`, `umount`, `sulogin`
and `nologin`.

#### 2. A tinyconfig kernel (`pkgs/os-specific/linux/kernel/tiny`)

`tinyconfig` plus the options a system names, without module support (a 2-line change to the kernel
builder lets `MODULES = no` through), so every option is built in or off:
- the NixOS modules' `system.requiredKernelConfig`, which the profile adds to the configuration;
- `nixos.nix`: what systemd needs beyond that for the appliance's features;
- `qemu.nix`: a QEMU guest's hardware;
- `uefi.nix`: booting as a UKI.

Options at their Kconfig default aren't listed. With `ignoreConfigErrors` off, an option whose dependencies
are missing fails the build. The low-memory choices were each measured by changing one at a time,
in QEMU at 256 MiB/3 CPUs and 512 MiB/1 CPU (MemAvailable 30 s after boot, means of three boots, noise about
100 KiB):

| choice | alternative | MemAvailable cost of the alternative | UKI cost of the alternative |
|---|---|--:|--:|
| `SLUB_TINY` | SLUB | −1.8 MiB (−3.8 MiB free) | +194 KB |
| `-Os`, plus `KCFLAGS=-Oz` | `-O2` | −1.4 MiB | +561 KB |
| `-Oz` over `-Os` | `-Os` alone | −116 to −144 KiB | +18 KB |
| `LOG_BUF_SHIFT=15` (32 KiB; a boot writes 22 KB before journald reads it; 14 lost messages) | 17 | −392 to −443 KiB | −0.5 KB |
| dentry/inode hash tables of 8192 entries | sized to RAM | −203 KiB at 256 MiB, −632 KiB at 512 MiB | 0 |
| no module support (`MODULES` off) | module support, with `TRIM_UNUSED_KSYMS` | −207 KiB at 256 MiB; −0.7 MiB at 512 MiB, less than those boots' 1.2 MiB spread | +16 KB |
| `ACPI_DEBUG` off | on (the default with ACPI) | −105 to −115 KiB | +49 KB |
| `BASE_SMALL` | off | within noise | −3 KB |
| GCC | clang 21 (thin LTO the same; full LTO worse) | −560 to −580 KiB | +221 KB |

SMP is on, for up to four CPUs (`NR_CPUS=4`; tinyconfig's 1 would clamp to 2). Against a uniprocessor kernel of this
configuration it costs 5.7 MiB of MemAvailable with one CPU and 6.7 MiB with three (a second per-CPU chunk,
slab, and an EROFS decompressor per CPU), and 102 KB of kernel. `SCHED_MC_PRIO`, on by default
with SMP, is off: it brings CPU frequency scaling, the Intel and AMD P-state drivers, and ACPI's processor
driver. A device that scales its CPUs' frequency turns those on in its own hardware file. In the QEMU guest
the ACPI processor driver is off, since without `CPU_FREQ` it warns at every boot.

#### 3. The store as an EROFS image, and a 22 KB stage 1 (`nixos/modules/profiles/embedded`)

`onefile-init.c` is the whole stage 1: static, an initrd of 22,080 bytes. It replaces NixOS's systemd initrd
(a second systemd, udev and coreutils) and does what nixos-init would. It:

- finds the system from `NIXOS_SYSTEM=` on the kernel command line;
- mounts the store, a tmpfs root with the store bound in (read-only, `nodev`, `nosuid`), `/run` and NixOS's
  etc overlay (systemd mounts `/dev` itself);
- `pivot_root`s out of the initramfs, which works since Linux 7.0 mounts the initramfs over nullfs;
- execs the system's systemd.

It serves both layouts, telling them apart by the root's file system type:

- **One-file UKI (`onefile.nix`)**: the initrd holds the init and the store image, archived by
  `makeInitrdNG` (the store appended to the init's archive, as netboot appends its store). The kernel unpacks
  it into a ramfs (`rootfstype=ramfs`), and EROFS mounts the image from that file directly, with no loop
  device and no copy (file-backed EROFS reads it page by page, which tmpfs can't). Before pivoting, the init
  deletes the initramfs's other files: the kernel never frees the detached initramfs (kdevtmpfs keeps a copy
  of the mount namespace from boot), and a ramfs frees a file once it's unlinked. The VM test checks that an
  8 MiB file appended to the initrd is freed.
- **Disk image (`image.nix`)**: a GPT disk with an ESP exactly as large as its files and a partition holding
  the same store image. The ESP is FAT12, computed from a fixed layout, and the build fails if it isn't the
  smallest; it includes systemd-stub's random seed. The kernel mounts the partition as its root itself
  (`root=PARTLABEL=store rootfstype=erofs rootwait`) and runs the init from it, so the UKI has no initrd
  at all (2,630,144 B).

The store image is EROFS with LZMA (512 KiB dictionary, which the kernel keeps in memory), packed tail
fragments and hardlinked duplicates. Store paths lose what no program reads at run time: manual and info
pages, documentation, shell completions and D-Bus interface descriptions.

#### 4. The NixOS configuration (`nixos/modules/profiles/embedded/default.nix`)

- **Profiles:** the `image-based-appliance` and `bashless` profiles; no Nix, no switching, no Perl, no Bash.
- **Logins:** none. No getty, shadow or PAM.
- **Services:** no D-Bus, logind or coredump; networkd, resolved and timesyncd; users from systemd-sysusers.
- **`/etc`:** read-only. With an empty machine-id each boot gets a transient one, and no boot is a first boot.
- **Units:** udev runs its own helpers, and units get no default `PATH`. The units NixOS configures that a
  systemd without kmod or PAM doesn't install are suppressed (`systemd.suppressedSystemUnits`); systemd-hwdb
  gets a file through `services.udev.extraHwdb`, and `boot.json` names no modprobe. A build-time check fails
  if any unit's program isn't among the multicall binary's.
- **Console:** the serial console's size and type are set on the command line, since each unanswered
  terminal query costs 333 ms.
- **sysctl:** settings of knobs the kernel lacks are marked `-` (systemd-sysctl then skips them quietly) or
  set to `null`.
- **Kernel requirements:** the NixOS modules' `system.requiredKernelConfig` is part of the kernel's
  configuration (NixOS doesn't check it for nixpkgs' kernels), and Linux 7.0 or later is asserted.
- **Time zones:** only UTC and the configured one.

### Changes to existing files

Everything else the profile needs, it sets through existing options. Each change is its own commit. For a
stock NixOS system (systemd with kmod and PAM):

| commit | what | a stock system |
|---|---|---|
| `nixos/sysctl` | mark `vm.mmap_rnd_compat_bits` `-`: kernels without 32-bit support lack it, and systemd-sysctl warned at every boot | the same setting, its line marked `-` |
| `systemd` | pass `withPam` through | unchanged |
| `nixos/tmpfiles` | link only the tmpfiles.d files the package installs (PAM's, machined's) | unchanged |
| `nixos/systemd`, `nixos/sysusers` | fsck, makefs, mkswap and sysusers' bind mounts run systemd's own util-linux, as the rest of `systemd.nix` and the initrd already do | these units use util-linux-minimal |
| `nixos/shadow` | require a console login method only when getty is on | unchanged |
| `nixos/sysusers` | no gshadow with a musl systemd, which doesn't write it | unchanged |
| `linux` | a kernel whose configuration sets `MODULES = no` gets no module support | unchanged (the same kernels) |

### Testing

- `nixos/tests/embedded` (`nix-build nixos/tests/embedded -A appliance`, `-A appliance-musl` and
  `-A appliance-mutable-etc`): the one-file system as a NixOS test VM on three CPUs, booted from its own
  stage 1. It checks:
  - PID 1 is the static binary, all three CPUs are online, and the system is `running`;
  - every unit's program exists and nothing dangles;
  - the store is the initramfs's image with no loop device, and nothing else of the initramfs stays in memory;
  - with the profile's read-only `/etc`, there's no first boot; the kernel's log holds the whole boot;
  - with a writable `/etc` (`appliance-mutable-etc`), writes land in the init's upper directory, and every
    boot is a first boot;
  - udev, mount units, seccomp, networkd, resolved, timesyncd and oomd work;
  - power-off goes through systemd-shutdown (seen failing without it), and the system boots again.
- `nixos/tests/embedded/boot-image.nix`: each layout under UEFI firmware, on the NixOS test driver with
  QEMU's own command line (as `nixos/tests/boot.nix` boots ISO images), reading only the serial console:
  - verbose, with no failure, error or warning on the console;
  - as shipped, reaching `running`;
  - at 256 MiB with 3 CPUs;
  - with a stage 1 that fails (it must say why, panic and reboot);
  - with the disk hot-plugged only once the kernel is waiting for it.
- `nixos/maintainers/scripts/embedded/matrix.sh` builds and boots every variant (both layouts, glibc and
  musl, MixOS); `verify-onefile.sh` checks from the UKI alone that it names its system and holds the whole
  closure, with no libc.

### Not in this PR

- The tests aren't in `nixos/tests/all-tests.nix`, and the packages aren't in `all-packages.nix`.
- nixpkgs' systemd is 261.3; the multicall package takes 262 itself and leaves out nixpkgs' zoneinfo
  patch, which doesn't apply to 262 (time zones stay in `/usr/share/zoneinfo`). nixpkgs PR #559244 (systemd
  262, open against staging) rebases that patch; once it's merged, the override goes.
- util-linux lists sqlite as a build input even without lastlog. Removing it is a mass rebuild, so it's left
  for staging; the profile passes `sqlite = null` meanwhile.
- The musl patch doesn't cover musl's own `abort()` calls, such as those in `__assert_fail`.

### Commits

13 commits on master, 35 files, +2,795/−14. The first seven are the changes to existing files above; then:

- `linux/kernel/tiny`: the kernel builder and its option sets;
- `systemd-multicall`: the package, its patches and the size overlay;
- `nixos/profiles/embedded`: the profile, the two layouts and the init;
- `nixos/tests/embedded`: the tests;
- `nixos/maintainers/scripts/embedded`: the matrix and the MixOS comparison;
- `nixos/maintainers/scripts/embedded`: this document, as README.md.

Each commit message carries its own measurements.
