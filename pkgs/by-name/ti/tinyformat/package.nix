{
  boost,
  cmake,
  fetchFromGitHub,
  fetchpatch,
  lib,
  stdenv,
  ninja,
}:

stdenv.mkDerivation (
  finalAttrs: {
    pname = "tinyformat";
    version = "0-unstable-2020-11-12";

    strictDeps = true;
    __contentAddressed = true;
    __structuredAttrs = true;

    src = fetchFromGitHub {
      owner = "c42f";
      repo = finalAttrs.pname;
      rev = "aef402d85c1e8f9bf491b72570bfe8938ae26727";
      hash = "sha256-Ka7fp5ZviTMgCXHdS/OKq+P871iYqoDOsj8HtJGAU3Y=";
    };

    patches = [
      (fetchpatch {
        # https://github.com/c42f/tinyformat/pull/87
        name = "cmake: update and add install targets";
        url = "https://github.com/ConnorBaker/tinyformat/commit/4805669b01d6a5f7fd61d6451f192950e4e36b9b.patch";
        hash = "sha256-xLoLEBG7WEN0F0aiaTTjG5Nx2cNTdZ2Im0RbHGv6lq0=";
      })
    ];

    nativeBuildInputs = [
      cmake
      ninja
    ];

    checkInputs = [
      boost
    ];

    doCheck = true;

    meta = with lib; {
      description = "Minimal, type safe printf replacement library for C";
      homepage = "https://github.com/c42f/tinyformat";
      license = licenses.boost;
      maintainers = with maintainers; [ SomeoneSerge ];
      mainProgram = "tinyformat";
      platforms = platforms.all;
    };
  }
)
