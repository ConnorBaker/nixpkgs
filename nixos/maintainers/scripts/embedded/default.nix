# Every variant: the embedded profile's tests and systems (nixos/tests/embedded), and MixOS's (./mixos.nix).
# `nix-build nixos/maintainers/scripts/embedded --keep-going -j1` builds and boots them one at a time; each one's
# log: nix log.
{
  nixpkgs ? ../../../..,
}:
let
  mixos = import ./mixos.nix { inherit nixpkgs; };
in
import ../../../tests/embedded { inherit nixpkgs; }
// {
  mixos-uki = mixos.uki;
  mixos-boot = mixos.boot;
}
