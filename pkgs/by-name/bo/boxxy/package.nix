{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  oniguruma,
  stdenv,
}:

rustPlatform.buildRustPackage rec {
  pname = "boxxy";
  version = "0.8.5";

  src = fetchFromGitHub {
    owner = "queer";
    repo = "boxxy";
    rev = "v${version}";
    hash = "sha256-6pb3yyC4/kpe8S67B3pzsSu3PfQyOWpiYi0JTBQk3lU=";
  };

  cargoHash = "sha256-L6EL8iP8FnV2WDe4bkHG/P5Zz4S9TAiw3V+XQSTABrQ=";

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    oniguruma
  ];

  env = {
    RUSTONIG_SYSTEM_LIBONIG = true;
  };

  meta = with lib; {
    description = "Puts bad Linux applications in a box with only their files";
    homepage = "https://github.com/queer/boxxy";
    license = licenses.mit;
    maintainers = with maintainers; [
      dit7ya
      figsoda
    ];
    platforms = platforms.linux;
    broken = stdenv.hostPlatform.isAarch64;
    mainProgram = "boxxy";
  };
}
