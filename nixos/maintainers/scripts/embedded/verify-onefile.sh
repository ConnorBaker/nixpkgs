#!/usr/bin/env bash
# Checks, from the UKI alone, that a one-file UKI (nixos/modules/profiles/embedded/onefile.nix) names its
# system, and holds all of it: its initrd is the init and the store image, which has every path of the
# toplevel's closure but those the UKI carries itself (the kernel, its modules, the initrd), and no libc.
# Usage: verify-onefile.sh MUSL(true|false). NIXPKGS: the nixpkgs to evaluate (default: the checkout this is
# in), whose binutils and erofs-utils it uses; xz and cpio come from PATH.
set -euo pipefail
nixpkgs=$(realpath "${NIXPKGS:-$(dirname "$0")/../../../..}")
cd "$(dirname "$0")"
musl=$1
appliance=(--arg nixpkgs "$nixpkgs" --arg musl "$musl" --argstr format onefile ../../../tests/embedded/appliance.nix)
system() { nix-instantiate --eval --raw -A "config.$1" "${appliance[@]}"; }
toplevel=$(system system.build.toplevel.outPath)
# The initrd's files, at their store paths (makeInitrdNG).
init=$(system system.build.init.outPath)
store=$(system system.build.storeImage.outPath)
etc=$(system system.build.etcMetadataImage.outPath)
# The paths the image leaves out, as it names them.
excluded=$(nix-instantiate --eval --raw --arg nixpkgs "$nixpkgs" --arg musl "$musl" --argstr format onefile -E \
  '{ nixpkgs, musl, format }: builtins.concatStringsSep "\n" (map toString
    (import ../../../tests/embedded/appliance.nix { inherit nixpkgs musl format; }).config.system.build.storeImage.excluded)')
ukis=$(nix-build --no-out-link -A config.system.build.uki "${appliance[@]}")
uki=$ukis/$(system system.boot.loader.ukiFile)
objcopy=$(nix-build --no-out-link "$nixpkgs" -A binutils)/bin/objcopy
# The erofs-utils that builds the image: 1.9.2 cannot read its packed fragments.
fsck_erofs=$(nix-build --no-out-link "$nixpkgs" -A erofs-utils)/bin/fsck.erofs
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
"$objcopy" -O binary --only-section=.cmdline "$uki" cmdline.txt
grep -qwF "NIXOS_SYSTEM=$toplevel" cmdline.txt || { echo "the command line does not name the system" >&2; exit 1; }
"$objcopy" -O binary --only-section=.initrd "$uki" initrd.bin
# Two xz streams, each a cpio archive: the init, then the store; nothing may follow them.
xz -dc initrd.bin > initrd.cpio
mkdir root
# (-u: both archives have makeInitrdNG's /run, /tmp and /var.)
(cd root && { cpio --quiet -idu; cpio --quiet -idu; [ "$(wc -c)" = 0 ]; } < ../initrd.cpio) ||
  { echo "the initrd is not two archives" >&2; exit 1; }
(cd root && find . -mindepth 1 -printf '%p %l\n' | sort) > initrd-files.txt
# Each file at its store path, linked from where the init looks for it.
printf '%s \n' ./nix ./nix/store ".$init" ".$store" ".$etc" ./run ./tmp ./var ./var/empty > expected-files.txt
printf '%s\n' "./init $init" "./store.erofs $store" "./etc-metadata-image $etc" "./var/run ../run" >> expected-files.txt
sort -o expected-files.txt expected-files.txt
diff expected-files.txt initrd-files.txt || { echo "the initrd holds other files than these" >&2; exit 1; }
"$fsck_erofs" --extract=store "root$store" > /dev/null
nix-store -qR "$toplevel" | grep -v -x -F "$excluded" | xargs -n1 basename | sort > closure.txt
find store/nix/store -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > image.txt
echo "closure paths: $(wc -l < closure.txt); in the image: $(comm -12 closure.txt image.txt | wc -l)"
# Every program is static: a libc means something dynamically linked came in.
if grep -E '^[a-z0-9]{32}-(glibc|musl)-' closure.txt; then echo "a libc is in the closure" >&2; exit 1; fi
missing=$(comm -23 closure.txt image.txt)
extra=$(comm -13 closure.txt image.txt)
[ -z "$missing" ] || { echo "missing from the image:"; echo "$missing"; exit 1; }
[ -z "$extra" ] || { echo "in the image beyond the toplevel's closure:"; echo "$extra"; exit 1; }
echo "the initrd is the program and the toplevel's closure, entirely"
