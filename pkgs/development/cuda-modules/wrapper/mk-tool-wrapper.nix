{
  lib,
  pkgsStatic,
}:
{
  name,
  description,
  env ? { },
}:
pkgsStatic.rustPlatform.buildRustPackage {
  inherit name env;

  src = ./rust;
  cargoLock.lockFile = ./rust/Cargo.lock;
  cargoBuildFlags = [
    "--bin"
    name
  ];
  cargoTestFlags = [ "--lib" ];

  meta = {
    inherit description;
    mainProgram = name;
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    teams = [ lib.teams.cuda ];
  };
}
