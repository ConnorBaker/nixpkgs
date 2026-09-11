{
  cudaAtLeast,
  cuda_culibos,
  lib,
  libnpp_plus,
  mkSamples,
}:
mkSamples {
  component = libnpp_plus;
  subtrees = [ "NPP+" ];
  # culibos moved out of cudart in CUDA 13.
  defaults.buildInputs = lib.optionals (cudaAtLeast "13") [ cuda_culibos ];

  # Headers live under include/nppPlus; the shipped namespace requires NPP_PLUS_ENABLE.
  defaults = {
    cmakeFlags = [
      (lib.cmakeFeature "NPP_PLUS_HEADER_PATH" "${lib.getInclude libnpp_plus}/include/nppPlus")
    ];
    postPatch = ''
      substituteInPlace "$sampleRoot/CMakeLists.txt" \
        --replace-fail '-DNPP_PLUS_ON' '-DNPP_PLUS_ENABLE'
    '';
  };
  fixups = {
    "NPP+".batchedLabelMarkersAndCompression.invocations = context: {
      batchedLabelMarkersAndCompression = import ../batched-label-invocation.nix (
        context // { inherit lib; }
      );
    };
    # Upstream concatenates "../images" without a slash and reads the floodFill inputs.
    "NPP+".distanceTransform.invocations = context: {
      DistanceTransform = {
        workSubdir = "build";
        dataFiles = lib.listToAttrs (
          map (name: lib.nameValuePair "images${name}" "${context.src}/NPP+/floodFill/images/${name}") [
            "DistanceSampler_512x512_8u.raw"
            "DistanceSampler_512x512_Inverted_8u.raw"
            "SignedCircle_256x206_64f.raw"
            "SignedCircle_256x206_Inverted_64f.raw"
            "SignedLith_554x554_32f.raw"
          ]
        );
        expectedOutputs = map (name: "images${name}") [
          "DistanceSamplerTransform_512x512_64f.raw"
          "DistanceSamplerTransform_512x512_Inverted_64f.raw"
          "DistanceSamplerTransform_512x512_16u.raw"
          "DistanceSamplerTransform_512x512_Inverted_16u.raw"
          "SignedDistanceCircleTransform_256x206_64f.raw"
          "SignedDistanceCircleTransform_256x206_16u.raw"
          "SignedDistanceCircleTransform_256x206_Inverted_64f.raw"
          "SignedDistanceCircleTransform_256x206_Inverted_16u.raw"
          "SignedDistanceLithTransform_554x554_64f.raw"
          "SignedDistanceLithTransform_554x554_16u.raw"
          "SignedDistanceLithTransformVoronoiIndices_554x554_16s.raw"
          "SignedDistanceLithTransformVoronoiRelativeManhattan_554x554_16s.raw"
        ];
      };
    };
    # Inputs remain declared even though the measured geometry failure disables execution.
    "NPP+".findContour.invocations = context: {
      findContour = {
        dataFiles = lib.genAttrs (map (name: "images/${name}") [ "CircuitBoard_2048x1024_8u.raw" ]) (
          name: "${context.src}/${context.sampleRoot}/${name}"
        );
        problems.nppPlusContourGeometryListsGarbage = {
          kind = "broken";
          message =
            "Sample NPP+/findContour segfaults walking the contour geometry lists produced by"
            + " nppPlusV::nppiCompressedMarkerLabelsUFContoursGenerateGeometryLists_C1R_Ctx, which"
            + " returns invalid bounding boxes (nID 1 Cnt 0 BB 0 0 1592984048 21892). Measured"
            + " against libnpp_plus 0.10.0.0 on the CUDA 12.6 and 12.9 package sets on an RTX 4090,"
            + " with the project's own CircuitBoard_2048x1024_8u.raw staged; this package set has"
            + " ${libnpp_plus.version}."
            + " Upstream:"
            + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/NPP+/findContour";
        };
      };
    };
    "NPP+".floodFill.invocations = context: {
      floodFill = {
        workSubdir = "build";
        dataFiles = lib.genAttrs (map (name: "images/${name}") [
          "RainbowChart_RGB_C3_1024x445_8u.raw"
          "SeabedSampler_RGB_C3_675x1024_8u.raw"
        ]) (name: "${context.src}/${context.sampleRoot}/${name}");
        expectedOutputs = map (name: "images/${name}") [
          "RainbowChart_RGB_C3_Fill_8Way_1024x445_Dev_8u.raw"
          "RainbowChart_RGB_C3_Fill_8Way_Gradient_1024x445_Dev_8u.raw"
          "RainbowChart_RGB_C3_Fill_8Way_Gradient_Boundary_1024x445_Dev_8u.raw"
          "SeabedSampler_RGB_C3_Fill_8Way_Range_675x1024_Dev_8u.raw"
          "SeabedSampler_RGB_C3_Fill_8Way_Range_Boundary_675x1024_Dev_8u.raw"
        ];
      };
    };
    # This variant writes four result kinds for three images, unlike the newer NPP program.
    "NPP+".watershedSegmentation.invocations =
      context:
      let
        images = {
          CT_skull = "512x512";
          Rocks = "512x512";
          Corn = "614x461";
        };
        results = {
          Segments = "8u";
          SegmentBoundaries = "8u";
          SegmentsWithContrastingBoundaries = "8u";
          CompressedSegmentLabels = "32u";
        };
      in
      {
        watershedSegmentation = {
          workSubdir = "build";
          dataFiles = lib.mapAttrs' (
            name: size:
            let
              path = "images/${name}_${size}_8u_Gray.raw";
            in
            lib.nameValuePair path "${context.src}/${context.sampleRoot}/${path}"
          ) images;
          expectedOutputs = lib.concatLists (
            lib.mapAttrsToList (
              kind: type:
              lib.mapAttrsToList (name: size: "images/${name}_${kind}_8Way_${size}_${type}.raw") images
            ) results
          );
        };
      };
  };
}
