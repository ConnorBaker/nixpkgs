#!/usr/bin/env bash
# Prints each program that a unit runs but that does not exist, and each unit link that dangles; exits 1 if
# there is any.
# Usage: check-unit-execs.sh BINDIR UNITDIR...
#   BINDIR: where the units' PATH finds bare names; UNITDIR: unit directories (generated ones included)
# OUTSIDE_STORE=0: skip absolute paths outside the store, at build time, where only the store exists.
# DANGLING=0: no check for dangling links, for generators' directories: their links name units where the
# package would have them, and systemd loads the units by name (nixos/tests/embedded/vm-test.nix checks
# that each is found). Commands prefixed with "-" count too: systemd then ignores even a missing program, so
# it fails silently.
set -euo pipefail
bindir=$1
shift
# A unit link whose unit is not there (an alias of a unit left out) would also make the grep below fail.
if [ "${DANGLING:-1}" = 0 ]; then
  dangling='' recurse=-r # regular files only: generated units, not the links to units
else
  dangling=$(find "$@" -xtype l) recurse=-R
fi
[ -z "$dangling" ] || { echo "dangling unit links:"; echo "$dangling"; exit 1; }
# grep's status 1, no match, is not an error: a generator's directory may hold no unit that runs anything.
missing=$(
  { grep "$recurse" -hE '^Exec(Start|Stop|Reload|Condition)[A-Za-z]*=' "$@" || [ $? = 1 ]; } |
    sed -E 's/^Exec[A-Za-z]*=//; s/^[-@:+!|]*//' | awk '{print $1}' | sort -u | while read -r cmd; do
      [ -n "$cmd" ] || continue # "ExecStart=" resets the list
      case $cmd in
        /nix/store/*) path=$cmd ;;
        /*) [ "${OUTSIDE_STORE:-1}" = 1 ] || continue; path=$cmd ;;
        plymouth) continue ;; # optional; not systemd's
        modprobe) continue ;; # modprobe@.service's, which runs only where kmod is (the embedded profile skips it)
        *) path=$bindir/$cmd ;;
      esac
      [ -e "$path" ] || echo "$cmd"
    done
)
[ -z "$missing" ] || { echo "$missing"; exit 1; }
