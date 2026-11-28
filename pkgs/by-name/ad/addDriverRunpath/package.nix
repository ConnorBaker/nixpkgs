{
  lib,
  stdenv,
  makeSetupHook,
}:
let
  # Named "opengl-driver" for legacy reasons, but it contains hardware drivers installed by NixOS.
  driverLink = "/run/opengl-driver" + lib.optionalString stdenv.hostPlatform.isi686 "-32";
in
makeSetupHook {
  name = "add-driver-runpath-hook";
  substitutions = { inherit driverLink; };

  # Test binaries may run before the fixup phase adds a driver RUNPATH.
  passthru.addDriverToLibraryPath = ''
    export LD_LIBRARY_PATH
    addToSearchPath LD_LIBRARY_PATH "${driverLink}/lib"
  '';

  meta.license = lib.licenses.mit;
} ./setup-hook.sh
