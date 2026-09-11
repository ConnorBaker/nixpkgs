{
  lib,
  libcublas,
  libcutensor,
  mkSamples,
}:
let
  importedLocationOf =
    libraryNameVariable: "\"\${CUTENSOR_ROOT}/\${LIB_DIR}/\${${libraryNameVariable}}\"";

  # Upstream imports from one versioned prefix; use the actual split library output.
  rewriteImportedLocation =
    libraryNameVariable:
    "--replace-fail ${lib.escapeShellArg (importedLocationOf libraryNameVariable)} ${lib.escapeShellArg "\"${lib.getLib libcutensor}/lib/\${${libraryNameVariable}}\""}";

in
mkSamples {
  component = libcutensor;
  # Both are independent projects; cuTENSORMg is not a child of cuTENSOR.
  subtrees = [
    "cuTENSOR"
    "cuTENSORMg"
  ];
  defaults.buildInputs = [ libcublas ];

  defaults.cmakeFlags = [
    (lib.cmakeFeature "CUTENSOR_ROOT" "${lib.getInclude libcutensor}")
  ];
  fixups = {
    cuTENSOR.postPatch = ''
      substituteInPlace "$sampleRoot/CMakeLists.txt" \
        ${rewriteImportedLocation "CUTENSOR_LIBRARY_NAME"}
    '';

    cuTENSORMg = {
      postPatch = ''
        substituteInPlace "$sampleRoot/CMakeLists.txt" \
          ${rewriteImportedLocation "CUTENSOR_LIBRARY_NAME"} \
          ${rewriteImportedLocation "CUTENSORMG_LIBRARY_NAME"}
      '';

      # blog_post requires a device count and scaling factor; use one device and the upstream factor.
      invocations.blog_post.args = [
        "1"
        "2"
      ];
    };
  };
}
