{
  cudaAtLeast,
  cuda_culibos,
  lib,
  libnpp,
  mkSamples,
}:
mkSamples {
  component = libnpp;
  subtrees = [ "NPP" ];
  # culibos moved out of cudart in CUDA 13.
  defaults.buildInputs = lib.optionals (cudaAtLeast "13") [ cuda_culibos ];

  fixups = {
    # The pinned source uses size_t for scratch size and processes all five inputs unconditionally.
    NPP.watershedSegmentation = {
      minCudaVersion = "12.8";
      invocations =
        context:
        let
          images = [
            "Lena_512x512_8u_Gray.raw"
            "CT_skull_512x512_8u_Gray.raw"
            "Rocks_512x512_8u_Gray.raw"
            "coins_500x383_8u_Gray.raw"
            "coins_overlay_500x569_8u_Gray.raw"
          ];
        in
        {
          watershedSegmentation = {
            workSubdir = "build";
            dataFiles = lib.genAttrs (map (name: "images/${name}") images) (
              name: "${context.src}/${context.sampleRoot}/${name}"
            );
            expectedOutputs = lib.concatMap (prefix: map (name: "images/${prefix}_${name}") images) [
              "Segmented"
              "Labels"
            ];
          };
        };
    };
    NPP.batchedLabelMarkersAndCompression.invocations = context: {
      batchedLabelMarkersAndCompression = import ../batched-label-invocation.nix (
        context // { inherit lib; }
      );
    };
    NPP.distanceTransform.invocations = context: {
      distanceTransform = {
        workSubdir = "build";
        dataFiles = lib.genAttrs (map (name: "images/${name}") [
          "Dolphin1_313x317_8u.raw"
          "TestImage3_diamond_64x64_8u.raw"
        ]) (name: "${context.src}/${context.sampleRoot}/${name}");
        expectedOutputs = map (name: "images/${name}") [
          "DistanceTransformVoronoi_Dolphin1_626x317_16s.raw"
          "DistanceTransformVoronoi_TestImage3_128x64_16s.raw"
          "DistanceTransformTrue_Dolphin1_313x317_32f.raw"
          "DistanceTransformTrue_TestImage3_diamond_64x64_32f.raw"
          "DistanceTransformTruncated_Dolphin1_313x317_16u.raw"
          "DistanceTransformTruncated_TestImage3_diamond_64x64_16u.raw"
        ];
      };
    };
    # This program uses images/; its siblings use ../images/ from a build subdirectory.
    NPP.findContour.invocations = context: {
      findContour = {
        dataFiles = lib.genAttrs (map (name: "images/${name}") [ "CircuitBoard_2048x1024_8u.raw" ]) (
          name: "${context.src}/${context.sampleRoot}/${name}"
        );
        # Direction output requires USE_NPP_11_5; reconstructed geometry is missing (see problem).
        expectedOutputs = map (name: "images/${name}") [
          "CircuitBoard_LabelMarkersUF_8Way_2048x1024_32u.raw"
          "CircuitBoard_CompressedMarkerLabelsUF_8Way_2048x1024_32u.raw"
          "CircuitBoard_Contours_8Way_2048x1024_8u.raw"
        ];

        problems.nppFindContourGeometryNondeterministic = {
          kind = "broken";
          message =
            "Sample NPP/findContour exits 0 without writing"
            + " images/CircuitBoard_ContoursReconstructed_8Way_2048x1024_8u.raw, and prints a"
            + " different compressed-label count on each run against identical input (274, 274, 269,"
            + " 270 measured on libnpp 12.4.1.87 with CUDA 12.9 on an RTX 4090; this package set has"
            + " ${libnpp.version}), which suggests a defect in the"
            + " contour-geometry step. Its NPP+ counterpart fails"
            + " the same way and segfaults outright. Upstream:"
            + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/NPP/findContour";
        };
      };
    };
  };
}
