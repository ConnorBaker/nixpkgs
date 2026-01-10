{
  lib,
  fetchurl,
  zlib,
  rdma-core,
  libpsm2,
  ucx,
  numactl,
  level-zero,
  pkg-config,
  libdrm,
  elfutils,
  xorg,
  glib,
  nss,
  nspr,
  dbus,
  at-spi2-atk,
  cups,
  gtk3,
  pango,
  cairo,
  mesa,
  expat,
  libxkbcommon,
  eudev,
  alsa-lib,
  ncurses5,
  bzip2,
  gdbm,
  libxcrypt-legacy,
  freetype,
  gtk2,
  gdk-pixbuf,
  fontconfig,
  libuuid,
  sqlite,

  intel-oneapi,

  # For tests
  runCommand,
  libffi,
  stdenv,
}:
intel-oneapi.mkIntelOneApi (fa: {
  pname = "intel-oneapi-base-toolkit";

  src = fetchurl {
    url = "https://registrationcenter-download.intel.com/akdlm/IRC_NAS/a04c89ad-d663-4f70-bd3d-bb44f5c16d57/intel-vtune-2025.7.0.248_offline.sh";
    hash = "sha256-S8BsVuqzaO4P9X6H6g9WNmPbbGDqP5z5ut8Wko5D4yE=";
  };

  versionYear = "2025";
  versionMajor = "7";
  versionMinor = "0";
  versionRel = "248";

  components = [
    "intel.oneapi.lin.vtune"
  ];

  # Figured out by looking at autoPatchelfHook failure output
  depsByComponent = rec {
    # advisor = [
    #   libdrm
    #   zlib
    #   gtk2
    #   gdk-pixbuf
    #   at-spi2-atk
    #   glib
    #   pango
    #   gdk-pixbuf
    #   cairo
    #   fontconfig
    #   glib
    #   freetype
    #   xorg.libX11
    #   xorg.libXxf86vm
    #   xorg.libXext
    #   xorg.libxcb
    #   xorg.libXcomposite
    #   xorg.libXdamage
    #   xorg.libXfixes
    #   xorg.libXrandr
    #   nss
    #   dbus
    #   cups
    #   mesa
    #   expat
    #   libxkbcommon
    #   eudev
    #   alsa-lib
    #   ncurses5
    #   bzip2
    #   libuuid
    #   gdbm
    #   libxcrypt-legacy
    #   sqlite
    #   nspr
    # ];
    # dpcpp-cpp-compiler = [
    #   zlib
    #   level-zero
    # ];
    # dpcpp_dbg = [
    #   level-zero
    #   zlib
    # ];
    # dpcpp-ct = [ zlib ];
    # mpi = [
    #   zlib
    #   rdma-core
    #   libpsm2
    #   ucx
    #   libuuid
    #   numactl
    #   level-zero
    #   libffi
    # ];
    # pti = [ level-zero ];
    vtune = [
      libdrm
      elfutils
      zlib
      xorg.libX11
      xorg.libXext
      xorg.libxcb
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXfixes
      xorg.libXrandr
      glib
      nss
      dbus
      at-spi2-atk
      cups
      gtk3
      pango
      cairo
      mesa
      expat
      libxkbcommon
      eudev
      alsa-lib
      at-spi2-atk
      ncurses5
      bzip2
      libuuid
      gdbm
      libxcrypt-legacy
      sqlite
      nspr
    ];
    # mkl = mpi ++ pti;
  };

  autoPatchelfIgnoreMissingDeps = [
    # Needs to be dynamically loaded as it depends on the hardware
    "libcuda.so.1"
    # All too old, not in nixpkgs anymore
    "libffi.so.6"
    "libgdbm.so.4"
    "libopencl-clang.so.14"
    # error: auto-patchelf could not satisfy dependency libsycl.so.8 wanted by /nix/store/x5j09xya1v33g8619k8006f20c6s5mqd-intel-oneapi-base-toolkit-2025.7.0.248/vtune/2025.7/bin64/self_check_apps/matrix.dpcpp/matrix.dpcpp
    "libsycl.so.8"
  ];

  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: the symlink /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/opt points to a missing target: /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/2025.7/opt
  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: the symlink /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/share points to a missing target: /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/2025.7/share
  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: the symlink /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/bin points to a missing target: /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/2025.7/bin
  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: the symlink /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/etc points to a missing target: /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/2025.7/etc
  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: the symlink /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/lib points to a missing target: /nix/store/mjr22mn3igccd70i44im4aa71qwawmk2-intel-oneapi-base-toolkit-2025.7.0.248/2025.7/lib
  # intel-oneapi-base-toolkit> ERROR: noBrokenSymlinks: found 5 dangling symlinks, 0 reflexive symlinks and 0 unreadable symlinks


  # intel-oneapi-base-toolkit> lrwxrwxrwx  1 nixbld nixbld   14 Oct 14 23:09 amplxe-vars.csh -> ./env/vars.csh
  # intel-oneapi-base-toolkit> lrwxrwxrwx  1 nixbld nixbld   13 Oct 14 23:09 amplxe-vars.sh -> ./env/vars.sh
  # intel-oneapi-base-toolkit> lrwxrwxrwx  1 nixbld nixbld   13 Oct 14 23:09 apsvars.sh -> ./env/vars.sh
  # intel-oneapi-base-toolkit> drwxr-xr-x  4 nixbld nixbld    6 Dec 14 06:19 backend
  # intel-oneapi-base-toolkit> drwxr-xr-x  2 nixbld nixbld    7 Dec 14 06:19 bin32
  # intel-oneapi-base-toolkit> drwxr-xr-x  7 nixbld nixbld   63 Dec 14 06:19 bin64
  # intel-oneapi-base-toolkit> drwxr-xr-x 23 nixbld nixbld   24 Dec 14 06:19 config
  # intel-oneapi-base-toolkit> drwxr-xr-x  3 nixbld nixbld    3 Dec 14 06:18 documentation
  # intel-oneapi-base-toolkit> drwxr-xr-x  2 nixbld nixbld    4 Dec 14 06:19 env
  # intel-oneapi-base-toolkit> drwxr-xr-x  4 nixbld nixbld    4 Dec 14 06:18 etc
  # intel-oneapi-base-toolkit> drwxr-xr-x 15 nixbld nixbld   23 Dec 14 06:19 frontend
  # intel-oneapi-base-toolkit> drwxr-xr-x  6 nixbld nixbld   14 Dec 14 06:19 include
  # intel-oneapi-base-toolkit> drwxr-xr-x  4 nixbld nixbld   44 Dec 14 06:19 lib32
  # intel-oneapi-base-toolkit> drwxr-xr-x  6 nixbld nixbld  206 Dec 14 06:19 lib64
  # intel-oneapi-base-toolkit> drwxr-xr-x  2 nixbld nixbld    4 Dec 14 06:19 licensing
  # intel-oneapi-base-toolkit> drwxr-xr-x  4 nixbld nixbld    4 Dec 14 06:18 message
  # intel-oneapi-base-toolkit> drwxr-xr-x  4 nixbld nixbld    7 Dec 14 06:19 resource
  # intel-oneapi-base-toolkit> drwxr-xr-x  3 nixbld nixbld    3 Dec 14 06:18 samples
  # intel-oneapi-base-toolkit> drwxr-xr-x  6 nixbld nixbld    6 Dec 14 06:18 sdk
  # intel-oneapi-base-toolkit> -rwxr-xr-x  1 nixbld nixbld 2798 Oct 14 21:03 sep_vars.sh
  # intel-oneapi-base-toolkit> -rwxr-xr-x  1 nixbld nixbld 2616 Oct 14 21:03 sep_vars_busybox.sh
  # intel-oneapi-base-toolkit> drwxr-xr-x  5 nixbld nixbld    5 Dec 14 06:18 sepdk
  # intel-oneapi-base-toolkit> drwxr-xr-x  3 nixbld nixbld    3 Dec 14 06:18 share
  # intel-oneapi-base-toolkit> drwxr-xr-x  3 nixbld nixbld    3 Dec 14 06:18 socwatch
  # intel-oneapi-base-toolkit> -rw-r--r--  1 nixbld nixbld   92 Oct 14 21:03 support.txt
  # intel-oneapi-base-toolkit> drwxr-xr-x  3 nixbld nixbld    3 Dec 14 06:18 target
  # intel-oneapi-base-toolkit> lrwxrwxrwx  1 nixbld nixbld   14 Oct 14 23:09 vtune-vars.csh -> ./env/vars.csh
  # intel-oneapi-base-toolkit> lrwxrwxrwx  1 nixbld nixbld   13 Oct 14 23:09 vtune-vars.sh -> ./env/vars.sh
  postInstall = ''
    rm -v "$out"/{opt,share,etc,lib,bin}
    ln -sfv "$out/vtune/${fa.versionYear}.${fa.versionMajor}/bin64" "$out/bin"
    ln -sfv "$out/vtune/${fa.versionYear}.${fa.versionMajor}/etc" "$out/etc"
    ln -sfv "$out/vtune/${fa.versionYear}.${fa.versionMajor}/include" "$out/include"
    ln -sfv "$out/vtune/${fa.versionYear}.${fa.versionMajor}/lib64" "$out/lib"
    ln -sfv "$out/vtune/${fa.versionYear}.${fa.versionMajor}/share" "$out/share"
  '';

  passthru.updateScript = intel-oneapi.mkUpdateScript {
    inherit (fa) pname;
    file = "base.nix";
    downloadPage = "https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html?packages=oneapi-toolkit&oneapi-toolkit-os=linux&oneapi-lin=offline";
  };

  passthru.tests = {
    mkl-libs = stdenv.mkDerivation {
      name = "intel-oneapi-test-mkl-libs";
      unpackPhase = ''
        cp ${./test.c} test.c
      '';

      nativeBuildInputs = [
        pkg-config
      ];
      buildInputs = [ intel-oneapi.base ];

      buildPhase = ''
        # This will fail if no libs with mkl- in their name are found
        libs="$(pkg-config --list-all | cut -d\  -f1 | grep mkl-)"
        for lib in $libs; do
          echo "Testing that the build succeeds with $lib" >&2
          gcc test.c -o test-with-$lib $(pkg-config --cflags --libs $lib)
        done
      '';

      doCheck = true;

      checkPhase = ''
        for lib in $libs; do
          echo "Testing that the executable built with $lib runs" >&2
          ./test-with-$lib
        done
      '';

      installPhase = ''
        touch "$out"
      '';
    };

    all-binaries-run = runCommand "intel-oneapi-test-all-binaries-run" { } ''
      # .*-32: 32-bit executables can't be properly patched by patchelf
      # IMB-.*: all fail with a weird "bad file descriptor" error
      # fi_info, fi_pingpong: exits with 1 even if ran with `--help`
      # gdb-openapi: Python not initialized
      # hydra_bstrap_proxy, hydra_nameserver, hydra_pmi_proxy: doesn't respect --help
      # mpirun: can't find mpiexec.hydra for some reason
      # sycl-ls, sycl-trace: doesn't respect --help
      regex_skip="(.*-32)|(IMB-.*)|fi_info|fi_pingpong|gdb-oneapi|hydra_bstrap_proxy|hydra_nameserver|hydra_pmi_proxy|mpirun|sycl-ls|sycl-trace"
      export I_MPI_ROOT="${intel-oneapi.base}/mpi/latest"
      for bin in "${intel-oneapi.base}"/bin/*; do
        if [[ "$bin" =~ $regex_skip ]] || [ ! -f "$bin" ] || [[ ! -x "$bin" ]]; then
          echo "skipping $bin"
          continue
        fi
        echo "trying to run $bin --help or -help"
        "$bin" --help || "$bin" -help
      done
      touch "$out"
    '';
  };

  meta = {
    description = "Intel oneAPI Base Toolkit";
    homepage = "https://software.intel.com/content/www/us/en/develop/tools/oneapi/base-toolkit.html";
    license = with lib.licenses; [
      intel-eula
      issl
      asl20
    ];
    maintainers = with lib.maintainers; [
      balsoft
    ];
    platforms = [ "x86_64-linux" ];
  };
})
