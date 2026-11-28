{
  autoAddCudaCompatRunpath,
  lib,
  patchelf,
  replaceVarsWith,
  runCommandCC,
  stdenv,
}:

let
  hostDirs = import ../cudaDriverSelector/host-directories.nix { inherit lib stdenv; };
  # A DT_NEEDED edge gives the host driver an inherited search path for its
  # companions. Keep this last-resort binding alive for the namespace.
  host = runCommandCC "nix-cuda-python-host.so" { nativeBuildInputs = [ patchelf ]; } ''
    $CC -nostdlib -shared -Wl,-z,nodelete,-z,noexecstack -x assembler /dev/null -o "$out"
    patchelf --add-needed libcuda.so.1 --force-rpath --set-rpath "${lib.concatStringsSep ":" hostDirs}" "$out"
  '';
in
replaceVarsWith {
  src = ./load-driver.py;
  replacements = {
    inherit host;
    lookup = autoAddCudaCompatRunpath.driverLookup.path or "";
    symbol = autoAddCudaCompatRunpath.driverLookup.symbol or "";
  };
  passthru = { inherit host; };
  meta = {
    description = "Lazy CUDA driver lookup for Python packages with a Nix-patched loader";
    platforms = lib.optionals (stdenv.hostPlatform.libc == "glibc") [
      "aarch64-linux"
      "x86_64-linux"
    ];
    license = lib.licenses.mit;
    teams = [ lib.teams.cuda ];
  };
}
