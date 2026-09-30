#!/usr/bin/env bash
# Builds and boots every variant, one after another: MixOS's UKI, NixOS's UKI (onefile) and disk image, glibc
# and musl, verbose and shipped boots, a boot whose stage 1 fails, one whose disk comes late, shipped boots
# with the least memory and most CPUs, and the VM tests (with a writable /etc too). Logs are <prefix>-*.log;
# prints one line per build, and exits 1 if any failed.
# Usage: matrix.sh PREFIX. NIXPKGS: the nixpkgs to evaluate (default: the checkout this is in).
set -u
nixpkgs=()
if [ -n "${NIXPKGS:-}" ]; then nixpkgs=(--arg nixpkgs "$(realpath "$NIXPKGS")"); fi
cd "$(dirname "$0")" || exit 1
t=../../../tests/embedded # the system (appliance.nix), its boot checks and its VM tests
p=${1:?usage: matrix.sh PREFIX}
failed=0

run() {
  local log=$1 status=0
  shift
  nix-build "${nixpkgs[@]}" "$@" > "$log" 2>&1 || status=$?
  echo "$log exit=$status"
  [ $status = 0 ] || failed=1
}

run "$p"-mixos-uki.log mixos/uki.nix -o result-"$p"-mixos-uki
run "$p"-mixos-boot.log mixos/boot.nix -o result-"$p"-mixos-boot
run "$p"-test-appliance.log $t -A appliance -o result-"$p"-test-appliance
run "$p"-test-appliance-musl.log $t -A appliance-musl -o result-"$p"-test-appliance-musl
run "$p"-test-appliance-mutable-etc.log $t -A appliance-mutable-etc -o result-"$p"-test-appliance-mutable-etc
for m in false true; do
  run "$p"-onefile-$m.log $t/appliance.nix --arg musl $m --argstr format onefile -A config.system.build.uki \
    -o result-"$p"-uki-musl-$m
  run "$p"-image-$m.log $t/appliance.nix --arg musl $m -A config.system.build.image -o result-"$p"-image-musl-$m
  for f in onefile image; do
    run "$p"-boot-$f-$m.log $t/boot-image.nix --arg musl $m --argstr format $f -o result-"$p"-boot-$f-musl-$m
    run "$p"-boot-shipped-$f-$m.log $t/boot-image.nix --arg musl $m --argstr format $f --arg verbose false \
      -o result-"$p"-boot-shipped-$f-musl-$m
  done
  run "$p"-boot-stage1-failure-$m.log $t/boot-image.nix --arg musl $m --argstr format onefile --arg stage1Failure true \
    -o result-"$p"-boot-stage1-failure-musl-$m
  run "$p"-boot-late-disk-$m.log $t/boot-image.nix --arg musl $m --arg lateDisk true -o result-"$p"-boot-late-disk-musl-$m
  # The least memory and the most CPUs of the devices this is for.
  for f in onefile image; do
    run "$p"-boot-small-$f-$m.log $t/boot-image.nix --arg musl $m --argstr format $f --arg verbose false --arg memory 256 \
      --arg cpus 3 -o result-"$p"-boot-small-$f-musl-$m
  done
done

stat -c '%s %n' result-"$p"-image-musl-*/*.raw
exit $failed
