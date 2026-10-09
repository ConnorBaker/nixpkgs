# Checks, from the UKI alone, that a one-file UKI (nixos/modules/profiles/embedded/onefile.nix) names its system and
# holds all of it: its initrd is the init and the store image, which has every path of the toplevel's closure but
# those the UKI carries itself (the kernel, its modules, the initrd), and no libc.
{ pkgs, config }:
let
  inherit (config.system.build)
    toplevel
    init
    storeImage
    etcMetadataImage
    ;
  uki = "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
in
pkgs.runCommand "embedded-onefile-contents"
  {
    nativeBuildInputs = with pkgs; [
      binutils
      cpio
      erofs-utils
      xz
    ];
    closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
    inherit (storeImage) excluded;
  }
  ''
    objcopy -O binary --only-section=.cmdline ${uki} cmdline.txt
    grep -qwF NIXOS_SYSTEM=${toplevel} cmdline.txt || { echo "the command line does not name the system"; exit 1; }
    objcopy -O binary --only-section=.initrd ${uki} initrd.bin
    # Two xz streams, each a cpio archive: the init, then the store; nothing may follow them.
    xz -dc initrd.bin > initrd.cpio
    mkdir root
    # (-u: both archives have makeInitrdNG's /run, /tmp and /var.)
    (cd root && { cpio --quiet -idu; cpio --quiet -idu; [ "$(wc -c)" = 0 ]; } < ../initrd.cpio) ||
      { echo "the initrd is not two archives"; exit 1; }
    (cd root && find . -mindepth 1 -printf '%p %l\n' | sort) > initrd-files.txt
    # Each file at its store path (makeInitrdNG), linked from where the init looks for it.
    {
      printf '%s \n' ./nix ./nix/store .${init} .${storeImage} .${etcMetadataImage} ./run ./tmp ./var ./var/empty
      printf '%s\n' "./init ${init}" "./store.erofs ${storeImage}" "./etc-metadata-image ${etcMetadataImage}" \
        "./var/run ../run"
    } | sort > expected-files.txt
    diff expected-files.txt initrd-files.txt || { echo "the initrd holds other files than these"; exit 1; }
    fsck.erofs --extract=store root${storeImage} > /dev/null
    printf '%s\n' $excluded > excluded.txt
    grep -v -x -F -f excluded.txt $closure/store-paths | xargs -n1 basename | sort > closure.txt
    find store/nix/store -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > image.txt
    echo "closure paths: $(wc -l < closure.txt); in the image: $(comm -12 closure.txt image.txt | wc -l)" | tee $out
    # Every program is static: a libc means something dynamically linked came in.
    if grep -E '^[a-z0-9]{32}-(glibc|musl)-' closure.txt; then echo "a libc is in the closure"; exit 1; fi
    missing=$(comm -23 closure.txt image.txt)
    extra=$(comm -13 closure.txt image.txt)
    [ -z "$missing" ] || { echo "missing from the image:"; echo "$missing"; exit 1; }
    [ -z "$extra" ] || { echo "in the image beyond the toplevel's closure:"; echo "$extra"; exit 1; }
  ''
