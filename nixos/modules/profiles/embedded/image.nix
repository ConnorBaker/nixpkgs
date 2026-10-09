# A disk image of the embedded system: an ESP holding the UKI, and the store image (./onefile.nix) as a
# partition, which the kernel mounts as its root.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  label = "store";
  uki = "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

  # systemd-repart makes an ESP of at least 100 MiB; firmware boots a FAT12 one as small as its contents. With
  # the layout fixed (512-byte sectors, one reserved, two FATs, a one-sector root directory, no alignment),
  # the size follows from the files'; the check at the end fails the build if it is not the least.
  #
  # It holds systemd-stub's random seed, 32 zero bytes the stub mixes with the firmware's RNG and rewrites in
  # place at each boot (src/boot/random-seed.c): missing, the stub would fail to create it on a full ESP, and
  # hand Linux no seed.
  esp =
    pkgs.buildPackages.runCommand "esp.img"
      {
        nativeBuildInputs = [
          pkgs.buildPackages.dosfstools
          pkgs.buildPackages.mtools
        ];
      }
      ''
        head -c 32 /dev/zero > random-seed
        dirs=(EFI EFI/BOOT loader)
        uki=$(stat -c %s ${uki}) seed=$(stat -c %s random-seed)
        sector=512 reserved=1 fats=2 root_entries=16
        # The smallest cluster that keeps FAT12 (under 4085 clusters): the files', and one for each directory.
        for per_cluster in 1 2 4 8 16 32 64 128; do
          cluster=$(( sector * per_cluster ))
          clusters=$(( (uki + cluster - 1) / cluster + (seed + cluster - 1) / cluster + ''${#dirs[@]} ))
          [ $clusters -lt 4085 ] && break
        done
        fat_sectors=$(( ((clusters + 2) * 3 / 2 + sector - 1) / sector )) # 12 bits a cluster, 2 reserved
        sectors=$(( reserved + fats * fat_sectors + root_entries * 32 / sector + clusters * per_cluster ))
        # mkfs.vfat -C takes the size in KiB.
        mkfs.vfat -C -a -F 12 -S $sector -s $per_cluster -R $reserved -f $fats -r $root_entries -n ESP "$out" \
          $(( (sectors + 1) / 2 ))
        mmd -i "$out" "''${dirs[@]/#/::/}"
        mcopy -i "$out" ${uki} ::/EFI/BOOT/BOOT${lib.toUpper pkgs.stdenv.hostPlatform.efiArch}.EFI
        mcopy -i "$out" random-seed ::/loader/random-seed
        # mtools groups the digits (65 536 bytes free).
        free=$(mdir -i "$out" ::/ | awk '/bytes free/ {gsub(/[^0-9]/, ""); print}')
        [ "$free" -lt $cluster ] || { echo "the ESP has $free bytes free" >&2; exit 1; }
      '';
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    ./onefile.nix
  ];

  embedded.storePartition = label;

  image.repart = {
    enable = true;
    name = "embedded";
    # Each partition as large as what it holds: repart's default minimum is 10 MiB, and 4 KiB its least
    # (HARD_MIN_SIZE).
    partitions = {
      esp.repartConfig = {
        Type = "esp";
        CopyBlocks = "${esp}";
        SizeMinBytes = "4K";
      };
      ${label}.repartConfig = {
        Type = "linux-generic";
        Label = label;
        CopyBlocks = "${config.system.build.storeImage}";
        SizeMinBytes = "4K";
      };
    };
  };
}
