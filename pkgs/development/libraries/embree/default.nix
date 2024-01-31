{
  cmake,
  ninja,
  fetchFromGitHub,
  glfw,
  glib,
  ispc,
  lib,
  pkg-config,
  stdenv,
  tbbLatest,
}:

stdenv.mkDerivation (
  finalAttrs: {
    pname = "embree";
    version = "4.3.0";

    strictDeps = true;
    __contentAddressed = true;

    src = fetchFromGitHub {
      owner = finalAttrs.pname;
      repo = finalAttrs.pname;
      rev = "v${finalAttrs.version}";
      hash = "sha256-Mk0xaY7QL6Xe0+pNz725iwMnzcXOsYz9Bm5H7fEj+8o=";
    };

    postPatch =
      # Fix duplicate /nix/store/.../nix/store/.../ paths
      ''
        sed -i \
          -e "s|SET(EMBREE_ROOT_DIR .*)|set(EMBREE_ROOT_DIR $out)|" \
          -e "s|$""{EMBREE_ROOT_DIR}/||" \
          common/cmake/embree-config.cmake
      '';

    cmakeFlags = [
      (lib.cmakeBool "EMBREE_TUTORIALS" false)
      (lib.cmakeBool "EMBREE_ISPC_SUPPORT" true)
    ];

    nativeBuildInputs = [
      ispc
      pkg-config
      ninja
      cmake
    ];

    buildInputs = [
      tbbLatest
      glfw
    ] ++ lib.optionals stdenv.isDarwin [ glib ];

    meta = with lib; {
      description = "High performance ray tracing kernels from Intel";
      homepage = "https://embree.github.io/";
      maintainers = with maintainers; [
        hodapp
        gebner
      ];
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
)
