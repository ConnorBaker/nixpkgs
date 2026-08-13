{
  cudaAtLeast,
  cuda_cudart,
  cuda_culibos,
  lib,
  libnpp,
  mkSamples,
}:
let
  sampleArgs = {
    # `nppiSegmentWatershedGetBufferSize_8u_C1R` changed its scratch-size out-parameter from
    # `int *` to `size_t *`, and the sample still passes an `int *`.
    #
    # The boundary is measured, not read off the release notes: the sample builds against CUDA 12.6
    # (libnpp 12.3.1.54, whose header still says `int *`) and fails to compile against 12.8
    # (libnpp 12.3.3.100) and every later package set. The header change is the actual cause, but
    # Nixpkgs ships exactly one libnpp per CUDA version, so the toolkit version identifies it
    # without a second axis.
    "NPP/watershedSegmentation".maxCudaVersion = "12.6";
  };

  # None of these four takes a path on the command line. Each opens its images through a `Path`
  # constant compiled into it -- `images/` for `findContour`, `../images/` for the other three -- and
  # writes its results back into the same directory, which is what `dataDir` names below; the three
  # which reach upward are run from the `build` subdirectory upstream's instructions leave you in.
  #
  # Only the *input* files are staged. Upstream's `images` directories also hold the expected
  # results, checked in beside them, and staging those would make every `expectedOutputs` entry true
  # before the program ran -- the vacuous check `mkTester`'s header describes, and the one
  # `findContour` was green for here.
  testArgs = {
    "NPP/batchedLabelMarkersAndCompression".batchedLabelMarkersAndCompression = {
      workSubdir = "build";
      dataDir = "images";
      dataFiles = [
        "lena_512x512_8u.raw"
        "CT_skull_512x512_8u.raw"
        "PCB_METAL_509x335_8u.raw"
        "PCB2_1024x683_8u.raw"
        "PCB_1280x720_8u.raw"
      ];
      # Three results per input: the label markers, their compressed renumbering, and the batched
      # form of the markers. The sample also names `*_CompressedMarkerLabelsUFBatch_*` files in its
      # sources and does not write them, so those are not expected here.
      expectedOutputs = [
        "Lena_LabelMarkersUF_8Way_512x512_32u.raw"
        "CT_skull_LabelMarkersUF_8Way_512x512_32u.raw"
        "PCB_METAL_LabelMarkersUF_8Way_509x335_32u.raw"
        "PCB2_LabelMarkersUF_8Way_1024x683_32u.raw"
        "PCB_LabelMarkersUF_8Way_1280x720_32u.raw"
        "Lena_CompressedMarkerLabelsUF_8Way_512x512_32u.raw"
        "CT_skull_CompressedMarkerLabelsUF_8Way_512x512_32u.raw"
        "PCB_METAL_CompressedMarkerLabelsUF_8Way_509x335_32u.raw"
        "PCB2_CompressedMarkerLabelsUF_8Way_1024x683_32u.raw"
        "PCB_CompressedMarkerLabelsUF_8Way_1280x720_32u.raw"
        "Lena_LabelMarkersUFBatch_8Way_512x512_32u.raw"
        "CT_skull_LabelMarkersUFBatch_8Way_512x512_32u.raw"
        "PCB_METAL_LabelMarkersUFBatch_8Way_509x335_32u.raw"
        "PCB2_LabelMarkersUFBatch_8Way_1024x683_32u.raw"
        "PCB_LabelMarkersUFBatch_8Way_1280x720_32u.raw"
      ];
    };

    "NPP/distanceTransform".distanceTransform = {
      workSubdir = "build";
      dataDir = "images";
      dataFiles = [
        "Dolphin1_313x317_8u.raw"
        "TestImage3_diamond_64x64_8u.raw"
      ];
      # The three transforms the sample computes -- Voronoi diagram, true distance and truncated
      # distance -- for each of its two images.
      expectedOutputs = [
        "DistanceTransformVoronoi_Dolphin1_626x317_16s.raw"
        "DistanceTransformVoronoi_TestImage3_128x64_16s.raw"
        "DistanceTransformTrue_Dolphin1_313x317_32f.raw"
        "DistanceTransformTrue_TestImage3_diamond_64x64_32f.raw"
        "DistanceTransformTruncated_Dolphin1_313x317_16u.raw"
        "DistanceTransformTruncated_TestImage3_diamond_64x64_16u.raw"
      ];
    };

    # The only one of the four whose `Path` is `images/` rather than `../images/`, so it runs from
    # the root of the working tree instead of a subdirectory of it.
    "NPP/findContour".findContour = {
      dataDir = "images";
      dataFiles = [ "CircuitBoard_2048x1024_8u.raw" ];
      # `CircuitBoard_ContoursDirection_8Way_2048x1024_8u.raw` is named in the sources beside these
      # four and is not written; the contour-direction image is only produced under `USE_NPP_11_5`.
      #
      # Only three are expected because the fourth is never produced -- see the problem below.
      expectedOutputs = [
        "CircuitBoard_LabelMarkersUF_8Way_2048x1024_32u.raw"
        "CircuitBoard_CompressedMarkerLabelsUF_8Way_2048x1024_32u.raw"
        "CircuitBoard_Contours_8Way_2048x1024_8u.raw"
      ];

      # This sample used to write all four outputs and give the same answer every time. Against the
      # 2025-10-09 samples it does neither, and it does not report a failure: it exits 0 having
      # produced three of the four, silently skipping `OUTPUT_GEOMETRY`, and the label count it
      # prints varies between runs on byte-identical input -- 274, 274, 269 and 270 over four
      # consecutive runs here, staging the same `CircuitBoard_2048x1024_8u.raw` each time. A count
      # that moves without the input moving is uninitialised memory being read, which is also the
      # most likely reason the geometry step produces nothing.
      #
      # Marked on the test rather than on the sample: it compiles, and the two other NPP projects
      # built from the same sources are unaffected.
      problems.nppFindContourGeometryNondeterministic = {
        kind = "broken";
        message =
          "Sample NPP/findContour exits 0 without writing"
          + " images/CircuitBoard_ContoursReconstructed_8Way_2048x1024_8u.raw, and prints a"
          + " different compressed-label count on each run against identical input (274, 274, 269,"
          + " 270 measured on libnpp 12.4.1.87 with CUDA 12.9 on an RTX 4090; this package set has"
          + " ${libnpp.version}), which indicates it reads uninitialised memory in the"
          + " contour-geometry step. Its NPP+ counterpart fails"
          + " the same way and segfaults outright. Upstream:"
          + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/NPP/findContour";
      };
    };

    # Measured, on `cudaPackages_12_6` (the only package set where this sample is available; see
    # `sampleArgs` above) on an RTX 4090: the run below writes exactly the files named here and exits
    # 0. The names had previously been read off the sources and never observed, and reading them was
    # not enough -- the sample segments `-b` images and defaults to three, so invoked with no
    # arguments it writes the twelve Lena/CT_skull/Rocks files and none of the eight `coins` ones,
    # and the test failed naming them. `-b 5` is what makes all five staged inputs contribute, and
    # five is the sample's own `NUMBER_OF_IMAGES`, past which it has no image to segment.
    "NPP/watershedSegmentation".watershedSegmentation = {
      workSubdir = "build";
      args = [
        "-b"
        "5"
      ];
      dataDir = "images";
      dataFiles = [
        "Lena_512x512_8u_Gray.raw"
        "CT_skull_512x512_8u_Gray.raw"
        "Rocks_512x512_8u_Gray.raw"
        "coins_500x383_8u_Gray.raw"
        "coins_overlay_500x569_8u_Gray.raw"
      ];
      expectedOutputs = [
        "Lena_Segments_8Way_512x512_8u.raw"
        "CT_skull_Segments_8Way_512x512_8u.raw"
        "Rocks_Segments_8Way_512x512_8u.raw"
        "coins_Segments_8Way_500x383_8u.raw"
        "coins_overlay_segments_500x569_8u.raw"
        "Lena_SegmentBoundaries_8Way_512x512_8u.raw"
        "CT_skull_SegmentBoundaries_8Way_512x512_8u.raw"
        "Rocks_SegmentBoundaries_8Way_512x512_8u.raw"
        "coins_SegmentBoundaries_8Way_500x383_8u.raw"
        "coins_overlay_SegmentBoundaries_8Way_500x569_8u.raw"
        "Lena_SegmentsWithContrastingBoundaries_8Way_512x512_8u.raw"
        "CT_skull_SegmentsWithContrastingBoundaries_8Way_512x512_8u.raw"
        "Rocks_SegmentsWithContrastingBoundaries_8Way_512x512_8u.raw"
        "coins_SegmentsWithContrastingBoundaries_8Way_500x383_8u.raw"
        "coins_overlay_SegmentsWithContrastingBoundaries_8Way_500x569_8u.raw"
        "Lena_CompressedSegmentLabels_8Way_512x512_32u.raw"
        "CT_skull_CompressedSegmentLabels_8Way_512x512_32u.raw"
        "Rocks_CompressedSegmentLabels_8Way_512x512_32u.raw"
        "coins_CompressedSegmentLabels_8Way_500x383_32u.raw"
        "coins_overlay_CompressedSegmentLabels_8Way_500x569_32u.raw"
      ];
    };
  };
in
mkSamples {
  component = libnpp;
  manifestPath = ./samples.json;
  # The subtrees of CUDALibrarySamples this component covers, and therefore the ones the manifest
  # check rescans. Stated here rather than read out of the manifest so that dropping a project from
  # the manifest cannot also drop the search which would have found it again.
  subtrees = [ "NPP" ];
  buildInputs = [
    cuda_cudart
  ]
  # Every project here ends its link line with `find_library(CULIBOS culibos ...)`, and CMake
  # refuses to generate when that comes back NOTFOUND. Through CUDA 12 `libculibos.a` ships inside
  # `cuda_cudart`, which these already have; CUDA 13 moved it into a component of its own.
  #
  # Gated on the toolkit version rather than on `cuda_culibos.meta.available`, as `cuda-samples.nix`
  # does. The two agree today, but they differ in the case that matters: if the component were ever
  # unavailable on a CUDA 13 set, availability would drop the input and leave CMake to fail with an
  # unexplained NOTFOUND, where the version test keeps it and lets `mkSamples` propagate the
  # component's own reason onto every sample.
  ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];
  inherit sampleArgs testArgs;
}
