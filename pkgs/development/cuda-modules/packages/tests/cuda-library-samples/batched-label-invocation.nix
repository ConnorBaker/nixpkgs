# Shared invocation data: NPP and NPP+ read and write the same five-image batch.
{
  lib,
  src,
  sampleRoot,
}:
let
  images = {
    lena = "512x512";
    CT_skull = "512x512";
    PCB_METAL = "509x335";
    PCB2 = "1024x683";
    PCB = "1280x720";
  };
in
{
  workSubdir = "build";
  dataFiles = lib.mapAttrs' (
    name: size:
    let
      path = "images/${name}_${size}_8u.raw";
    in
    lib.nameValuePair path "${src}/${sampleRoot}/${path}"
  ) images;
  # Upstream capitalizes Lena only in output names. It names compressed batch outputs
  # in its sources but never writes them; only these three results per image are expected.
  expectedOutputs =
    lib.concatMap
      (
        kind:
        lib.mapAttrsToList (
          name: size: "images/${if name == "lena" then "Lena" else name}_${kind}_${size}_32u.raw"
        ) images
      )
      [
        "LabelMarkersUF_8Way"
        "CompressedMarkerLabelsUF_8Way"
        "LabelMarkersUFBatch_8Way"
      ];
}
