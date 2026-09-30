/* Stage 1 of the embedded profile (./onefile.nix, ./image.nix), in place of NixOS's: PID 1 until it executes
 * the system's systemd, after the mounts NixOS's systemd initrd and nixos-init would make.
 *
 * The system is NIXOS_SYSTEM=, from the kernel's command line (the kernel hands on such parameters as
 * environment variables); it links its etc metadata image and basedir. The store is an EROFS image laid out
 * as a root file system (/nix/store, and the mount point /sysroot):
 * - a disk image's partition, which the kernel mounts as its root (root=PARTLABEL=, rootfstype=erofs,
 *   rootwait), with this program as init=;
 * - a one-file UKI's /store.erofs, in the initramfs, which must then be a ramfs (rootfstype=ramfs): EROFS
 *   mounts an image file without a loop device only from a file system that can read it page by page
 *   (read_folio), which tmpfs cannot. The etc metadata image is the initramfs's copy: EROFS mounts no image
 *   from a file on an EROFS that is itself mounted from a file (fs/erofs/super.c).
 *
 * The new root is a tmpfs with the store bound in. This program moves into it (pivot_root, which works from
 * the initramfs since Linux 7.0 mounts it over nullfs) and detaches the old root, which the kernel never
 * frees: kdevtmpfs keeps a copy of the mount namespace from before. So it first removes the initramfs's
 * files, whose memory a ramfs frees once they are unlinked (not the two images, which EROFS holds open).
 * Every failure ends it, which the kernel reports as a panic. */

#define _GNU_SOURCE /* asprintf, nftw */
#include <errno.h>
#include <ftw.h>
#include <linux/magic.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <unistd.h>

/* NixOS's etc overlay (etc-activation.nix), as ./onefile.nix derives it: whether it is writable, its mount
 * flags, and its data, a format of the system's path; and the targets of /usr/bin/env and /bin/sh, or NULL. */
#if !defined(ETC_MUTABLE) || !defined(ETC_FLAGS) || !defined(ETC_DATA) || !defined(ENV_BINARY) || \
        !defined(SH_BINARY)
#error "ETC_MUTABLE, ETC_FLAGS, ETC_DATA, ENV_BINARY and SH_BINARY must be defined (./onefile.nix)"
#endif
static const char *const env_binary = ENV_BINARY, *const sh_binary = SH_BINARY;

#define NEW_ROOT "/sysroot"

static void die(const char *what) {
        fprintf(stderr, "init: %s: %s\n", what, strerror(errno));
        _exit(1);
}

__attribute__((format(printf, 1, 2)))
static char *format(const char *fmt, ...) {
        va_list args;
        char *s;

        va_start(args, fmt);
        if (vasprintf(&s, fmt, args) < 0)
                die(fmt);
        va_end(args);
        return s;
}

static void make_dir(const char *path) {
        if (mkdir(path, 0755) < 0 && errno != EEXIST)
                die(path);
}

static void do_mount(const char *source, const char *target, const char *type, unsigned long flags,
                     const char *data) {
        make_dir(target);
        if (mount(source, target, type, flags, data) < 0)
                die(target);
}

static void link_to(const char *target, const char *path) {
        if (symlink(target, path) < 0)
                die(path);
}

/* Removes a file or directory of the initramfs; nftw (FTW_MOUNT) passes none of the file systems mounted on
 * it. */
static int remove_entry(const char *path, const struct stat *st, int type, struct FTW *ftw) {
        (void) st;
        (void) type;
        if (ftw->level > 0 && remove(path) < 0)
                die(path);
        return 0;
}

int main(int argc, char *argv[]) {
        const char *system = getenv("NIXOS_SYSTEM");

        (void) argc;
        if (!system) {
                errno = EINVAL;
                die("no NIXOS_SYSTEM= on the kernel's command line");
        }

        /* The root: a one-file UKI's initramfs, or a disk image's store. */
        struct statfs root_fs;
        if (statfs("/", &root_fs) < 0)
                die("statfs /");
        /* f_type is signed on some 32-bit libcs; the magic numbers are unsigned. */
        const unsigned long root_type = (unsigned long) root_fs.f_type;
        const bool onefile = root_type == RAMFS_MAGIC;
        if (!onefile && root_type != EROFS_SUPER_MAGIC_V1) {
                errno = EINVAL;
                die("the root is neither a ramfs (rootfstype=ramfs) nor the store (rootfstype=erofs)");
        }
        const char *store = "/nix/store", *etc_image = format("%s/etc-metadata-image", system);
        if (onefile) {
                do_mount("/store.erofs", "/store", "erofs", MS_RDONLY | MS_NODEV | MS_NOSUID, NULL);
                store = "/store/nix/store";
                etc_image = "/etc-metadata-image";
        }

        /* The system's root, as its fileSystems say, and the tmpfs /run, which systemd would mount itself
         * (with its options) but this program writes to. */
        do_mount("tmpfs", NEW_ROOT, "tmpfs", 0, "mode=0755");
        make_dir(NEW_ROOT "/nix");
        do_mount(store, NEW_ROOT "/nix/store", NULL, MS_BIND, NULL);
        /* A bind keeps its source's flags, and a disk image's root is only read-only. */
        if (mount(NULL, NEW_ROOT "/nix/store", NULL, MS_REMOUNT | MS_BIND | MS_RDONLY | MS_NODEV | MS_NOSUID,
                  NULL) < 0)
                die(NEW_ROOT "/nix/store");
        do_mount("tmpfs", NEW_ROOT "/run", "tmpfs", MS_NOSUID | MS_NODEV | MS_STRICTATIME,
                 "mode=0755,size=20%,nr_inodes=800k");
        do_mount(etc_image, NEW_ROOT "/run/nixos-etc-metadata", "erofs", MS_RDONLY | MS_NODEV | MS_NOSUID,
                 NULL);

        /* A NixOS system, as nixos-init requires of init= (verify_init_is_nixos). */
        if (access(format(NEW_ROOT "%s/nixos-version", system), F_OK) < 0)
                die("NIXOS_SYSTEM= is not a NixOS system");

        /* musl's nftw descends at most as many levels as it may hold descriptors; the initramfs is 2 deep. */
        if (onefile && nftw("/", remove_entry, 16, FTW_DEPTH | FTW_MOUNT | FTW_PHYS) < 0)
                die("remove the initramfs's files");
        if (chdir(NEW_ROOT) < 0 || syscall(SYS_pivot_root, ".", ".") < 0 || umount2(".", MNT_DETACH) < 0 ||
            chdir("/") < 0)
                die("move into " NEW_ROOT);

        if (ETC_MUTABLE) {
                make_dir("/.rw-etc");
                make_dir("/.rw-etc/upper");
                make_dir("/.rw-etc/work");
        }
        do_mount("overlay", "/etc", "overlay", ETC_FLAGS, format(ETC_DATA, system));

        /* What nixos-init's activation does (activate.rs) that this system needs: no modules, no firmware. */
        link_to(system, "/run/current-system");
        link_to(system, "/run/booted-system");
        if (env_binary) {
                make_dir("/usr");
                make_dir("/usr/bin");
                link_to(env_binary, "/usr/bin/env");
        }
        if (sh_binary) {
                make_dir("/bin");
                link_to(sh_binary, "/bin/sh");
        }

        unsetenv("NIXOS_SYSTEM");
        argv[0] = format("%s/systemd/lib/systemd/systemd", system);
        execv(argv[0], argv);
        die(argv[0]);
}
