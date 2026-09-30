# tinyconfig plus the options given, without module support (every option built in or off): the kernel of the
# embedded profile, and of nixos/maintainers/scripts/embedded/mixos. With ignoreConfigErrors off, an option
# whose dependencies are not enabled fails the build rather than being dropped.
{
  lib,
  linux,
  # lib.kernel values, on top of `common`.
  config,
}:
# tinyconfig's xz-compressed kernel (x86's tiny.config), the XZ_DEC_ filters and ./uefi.nix's ACPI are x86's.
assert lib.assertMsg linux.stdenv.hostPlatform.isx86
  "pkgs/os-specific/linux/kernel/tiny: only x86 option sets";
let
  inherit (lib.kernel)
    yes
    no
    option
    freeform
    ;

  # What tinyconfig leaves out and both systems' userspace needs: to run programs (ELF, #! scripts, users),
  # the pseudo file systems their init mounts, a compressed initrd holding a compressed EROFS store image, and
  # the syscalls both inits use (MixOS's module.nix asserts EPOLL, EVENTFD, FUTEX, TIMERFD).
  common = {
    PRINTK = yes;
    TTY = yes;
    MULTIUSER = yes;
    BINFMT_ELF = yes;
    BINFMT_SCRIPT = yes;
    FUTEX = yes;
    EPOLL = yes;
    EVENTFD = yes;
    TIMERFD = yes;
    SHMEM = yes;
    TMPFS = yes;
    FILE_LOCKING = yes;
    POSIX_TIMERS = yes;
    PROC_FS = yes;
    SYSFS = yes;
    DEVTMPFS = yes;
    NET = yes;
    UNIX = yes;
    BLOCK = yes;
    BLK_DEV_INITRD = yes;
    MISC_FILESYSTEMS = yes;
    EROFS_FS = yes;
    OVERLAY_FS = yes; # /etc
    # No modules: every option is built in, or off.
    MODULES = no;
    X86_PKG_TEMP_THERMAL = option no; # a module by default, with THERMAL

    ACPI_DEBUG = no; # on by default with ACPI

    # For devices of 256-512 MiB and fewer than four cores:
    # - a 32 KiB log, the least that holds what a boot writes before journald reads it (22 KB in the VM test,
    #   which checks it); hardware with more to say at boot may need more;
    # - smaller core tables (BASE_SMALL): at most 32768 processes on x86, 16 futex buckets for the whole system
    #   and no per-process ones, XArray nodes (the page cache's index) of 16 slots rather than 64, smaller UDP,
    #   user and timer tables. Its costs grow with cores and with busy multithreaded programs.
    # - SMP for up to four CPUs (tinyconfig's NR_CPUS of 1 would clamp to 2), which costs memory even with one
    #   (a second per-CPU chunk, slab, an EROFS decompressor per CPU); a larger NR_CPUS costs no more.
    LOG_BUF_SHIFT = freeform "15";
    BASE_SMALL = yes;
    SMP = yes;
    NR_CPUS = freeform "4";
    # On by default with SMP, for Turbo Boost Max 3.0 cores; it brings CPU frequency scaling, its Intel and AMD
    # drivers and ACPI's processor driver, which a device that scales its CPUs turns on itself.
    SCHED_MC_PRIO = no;
    # One decompressor for the initrd, xz (both systems compress theirs with it), and its filters for x86
    # code only.
    RD_GZIP = no;
    RD_BZIP2 = no;
    RD_LZMA = no;
    RD_LZO = no;
    RD_LZ4 = no;
    RD_ZSTD = no;
    XZ_DEC_ARM = no;
    XZ_DEC_ARMTHUMB = no;
    XZ_DEC_ARM64 = no;
    XZ_DEC_POWERPC = no;
    XZ_DEC_RISCV = no;
    XZ_DEC_SPARC = no;
  };
in
linux.override {
  defconfig = "tinyconfig";
  enableCommonConfig = false;
  autoModules = false;
  ignoreConfigErrors = false;
  # -Oz after the kernel's -Os (CC_OPTIMIZE_FOR_SIZE, tinyconfig's).
  extraMakeFlags = [ "KCFLAGS=-Oz" ];
  structuredExtraConfig = common // config;
}
