# Boots MixOS's UKI (./uki.nix) with UEFI firmware, as nixos/tests/embedded/boot-image.nix boots the NixOS
# one: from an ESP holding nothing else (QEMU's virtual FAT drive of a directory). At its askfirst console it
# must run a command from its root filesystem: `echo MIXOS-OK-$((6*7))` prints MIXOS-OK-42 only if a shell
# evaluates it (the echo of the typed line does not contain 42). red = true types 6*6 instead, which must
# fail.
# Arguments: those of ./default.nix, and red.
{
  nixpkgs ? ../../../../..,
  red ? false,
  ...
}@args:
let
  pkgs = import nixpkgs { };
  uki = import ./uki.nix (removeAttrs args [ "red" ]);
in
pkgs.runCommand "mixos-boot${pkgs.lib.optionalString red "-red"}"
  {
    requiredSystemFeatures = [ "kvm" ];
    nativeBuildInputs = [ pkgs.qemu_kvm ];
  }
  ''
    install -Dm444 ${uki}/mixos.efi esp/EFI/BOOT/BOOTX64.EFI
    mkfifo serial.in serial.out
    exec 3<>serial.in # a read-write open never blocks, whether or not QEMU still runs
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 512 -no-reboot -display none -monitor none \
      -bios ${pkgs.OVMF.fd}/FV/OVMF.fd -drive if=virtio,format=raw,file=fat:esp,readonly=on \
      -serial pipe:serial &
    qemu=$!
    : > console.log # for tail, before the reader first writes
    cat serial.out >> console.log &
    reader=$!

    # Whether a line of the console matches $1 (an extended regular expression) before MixOS panics, QEMU
    # ends, or 20 s pass (a hang), waiting as nixos/tests/embedded/boot-image.nix does, but with awk for sed:
    # busybox's prompts end no line. awk takes the console a record at a time, a record ending at each space
    # (a one-character RS, which unlike a regular expression needs no lookahead); after each it matches the
    # lines, the last even unfinished. Everything waited for here ends with a space or has one soon after.
    started=''${EPOCHREALTIME/./}
    elapsed() { local now=''${EPOCHREALTIME/./}; echo $(( (now - started) / 1000 )); }
    wait_for() {
      local left=$(( 20000 - $(elapsed) )) watcher timer
      tail -n +1 -f console.log | awk -v RS=' ' -v re="$1|Kernel panic" '
        { gsub(/\r/, ""); n = split(line RS $0, lines, "\n"); line = lines[n] }
        { for (i = 1; i <= n; i++) if (lines[i] ~ re) { print lines[i]; exit } }
      ' > match.txt &
      watcher=$!
      sleep "$(( left > 0 ? left / 1000 : 0 )).$(printf %03d $(( left > 0 ? left % 1000 : 0 )))" &
      timer=$!
      wait -n "$qemu" "$watcher" "$timer" || true
      kill "$watcher" "$timer" 2>/dev/null || true
      if grep -qE "$1" match.txt; then echo "$1 after $(elapsed) ms"; return 0; fi
      echo "no $1 after $(elapsed) ms: $(cat match.txt)" >&2
      return 1
    }

    ok=0
    if wait_for 'Please press Enter to activate this console'; then
      printf '\n' >&3
      # busybox's shell, once it reads what is typed.
      if wait_for '/ #$'; then
        printf 'echo MIXOS-OK-$((6*${if red then "6" else "7"}))\n' >&3
        if wait_for 'MIXOS-OK-42'; then ok=1; fi
      fi
    fi
    kill $qemu 2>/dev/null || true
    wait $qemu || true
    # The reader ends at QEMU's closing its end, or, if QEMU never opened it, at this open and close.
    exec 4<>serial.out 4>&-
    wait $reader
    tr '\r' '\n' < console.log > console.txt
    cat console.txt
    [ $ok = 1 ]
    install -Dm444 console.txt "$out/console.txt"
  ''
