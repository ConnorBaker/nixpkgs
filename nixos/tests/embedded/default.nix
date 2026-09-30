# The embedded profile's VM test: the system on glibc and on musl, and with a writable /etc.
{
  nixpkgs ? ../../..,
}:
let
  pkgs = import nixpkgs { };
  test =
    args:
    pkgs.testers.runNixOSTest {
      imports = [ (import ./vm-test.nix args) ];
      node.pkgsReadOnly = false; # the profile and ./platform.nix set nixpkgs options
    };
in
{
  appliance = test { musl = false; };
  appliance-musl = test { musl = true; };
  appliance-mutable-etc = test {
    musl = true;
    mutableEtc = true;
  };
}
