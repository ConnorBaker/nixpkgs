{
  lib,
  fetchFromGitHub,
  rustPlatform,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "tool-wrapper";
  version = "0.1.0-unstable-2026-11-26";

  src = fetchFromGitHub {
    owner = "ConnorBaker";
    repo = "tool-wrapper";
    rev = "7366fc4dc4b175d99cff84341bca7af4defb6387";
    hash = "sha256-xCrNU3qh9sQVEkBJRc4HDxcg0sllF7xcCHUVRx1Btrg=";
  };

  cargoHash = "sha256-0zGrhU1KXMtxwqMhBKwtuZEXw+UM/qMg/E8vcLKDTjo=";
  buildFeatures = [ "wrapper" ];
  cargoTestFlags = [
    "--all-features"
    "--all-targets"
  ];

  passthru.installAdjacentWrapper = "${finalAttrs.src}/nix/install-adjacent-wrapper.sh";

  meta = {
    description = "Linux executable wrappers and reproducible artifact editing";
    homepage = "https://github.com/ConnorBaker/tool-wrapper";
    license = lib.licenses.mit;
    maintainers = [ lib.maintainers.connorbaker ];
    mainProgram = "tool-wrapper";
    platforms = lib.platforms.linux;
  };
})
