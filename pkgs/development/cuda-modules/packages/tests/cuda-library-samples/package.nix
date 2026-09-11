{ callPackage, lib }:
let
  components = lib.packagesFromDirectoryRecursive {
    inherit callPackage;
    directory = ./components;
  };
in
lib.recurseIntoAttrs (
  lib.zipAttrsWith
    (
      name: roots:
      assert lib.assertMsg (
        lib.length roots == 1
      ) "sample directory ${name} belongs to multiple components";
      lib.head roots
    )
    (
      map (
        tree:
        removeAttrs tree [
          "override"
          "overrideDerivation"
          "recurseForDerivations"
        ]
      ) (lib.attrValues components)
    )
)
