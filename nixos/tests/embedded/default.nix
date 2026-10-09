# The embedded profile's tests, and the systems they boot. Each attribute is one; `nix-build nixos/tests/embedded
# --keep-going -j1` builds them all, one at a time (each one's log: nix log).
# - appliance*: the one-file system as a NixOS test VM (./vm-test.nix), on glibc and on musl, and with a writable /etc;
# - uki*, image*: the systems (./appliance.nix), one-file and disk image; onefile-contents*: what the UKI holds
#   (./onefile-contents.nix);
# - boot-*: each layout booted under UEFI firmware (./boot-image.nix), verbose and as shipped; a stage 1 that fails;
#   a disk that comes late; and as shipped with the least memory and the most CPUs of the devices this is for.
{
  nixpkgs ? ../../..,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  test =
    args:
    pkgs.testers.runNixOSTest {
      imports = [ (import ./vm-test.nix args) ];
      node.pkgsReadOnly = false; # the profile and ./appliance.nix set nixpkgs options
    };
  system = args: (import ./appliance.nix ({ inherit nixpkgs; } // args)).config;
  onefile.format = "onefile";
  shipped.verbose = false;
  small = shipped // {
    memory = 256;
    cpus = 3;
  };
  perLibc =
    musl:
    let
      onefileSystem = system (onefile // { inherit musl; });
    in
    lib.mapAttrs' (name: lib.nameValuePair (name + lib.optionalString musl "-musl")) (
      {
        uki = onefileSystem.system.build.uki;
        onefile-contents = import ./onefile-contents.nix {
          inherit pkgs;
          config = onefileSystem;
        };
        image = (system { inherit musl; }).system.build.image;
      }
      // lib.mapAttrs (name: args: import ./boot-image.nix (args // { inherit nixpkgs musl name; })) {
        boot-onefile = onefile;
        boot-image = { };
        boot-shipped-onefile = shipped // onefile;
        boot-shipped-image = shipped;
        boot-stage1-failure = onefile // {
          stage1Failure = true;
        };
        boot-late-disk.lateDisk = true;
        boot-small-onefile = small // onefile;
        boot-small-image = small;
      }
    );
in
{
  appliance = test { musl = false; };
  appliance-musl = test { musl = true; };
  appliance-mutable-etc = test {
    musl = true;
    mutableEtc = true;
  };
}
// perLibc false
// perLibc true
