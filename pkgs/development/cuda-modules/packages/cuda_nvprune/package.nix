{
  buildRedist,
  callPackage,
  lib,
  runCommandCC,
}:
buildRedist (finalAttrs: {
  redistName = "cuda";
  pname = "cuda_nvprune";

  outputs = [ "out" ];

  postInstall = lib.optionalString finalAttrs.finalPackage.meta.available ''
    nixLog "wrapping nvprune to normalize archive member timestamps"
    mv --verbose "''${!outputBin:?}/bin/nvprune" "''${!outputBin:?}/bin/.nvprune-wrapped"
    install --mode=0755 "${finalAttrs.passthru.nvpruneWrapper}/bin/nvprune-wrapper" "''${!outputBin:?}/bin/nvprune"
  '';

  passthru.nvpruneWrapper = callPackage ../../wrapper/mk-tool-wrapper.nix { } {
    name = "nvprune-wrapper";
    description = "Wrapper for reproducible nvprune archives";
  };

  passthru.tests.reproducible =
    runCommandCC "nvprune-reproducible"
      {
        nativeBuildInputs = [ finalAttrs.finalPackage ];
      }
      ''
        printf '%s\n' 'int example(void) { return 42; }' | "$CC" -x c -c - -o example.o
        for mtime in 1470000000 1900000000; do
          touch -d "@$mtime" example.o
          ar crU "$mtime.a" example.o
          touch -d "@$mtime" "$mtime.a"
        done
        printf '%s\n' '-arch=sm_80 -o "from options.a"' > prune.optf
        printf '%s\n' '-optf prune.optf' > nested.optf
        nvprune --options-file=nested.optf 1470000000.a
        nvprune -arch=sm_80 --output-file=second.a 1900000000.a
        cmp 'from options.a' second.a
        ar p second.a example.o > from-archive.o
        cmp example.o from-archive.o
        nvprune -arch=sm_80 -o standalone.o example.o
        cmp example.o standalone.o
        touch "$out"
      '';

  meta = {
    description = "Prune host object files and libraries to only contain device code for the specified targets";
    longDescription = ''
      `nvprune` prunes host object files and libraries to only contain device code for the specified targets.
    '';
    homepage = "https://docs.nvidia.com/cuda/cuda-binary-utilities#nvprune";
  };
})
