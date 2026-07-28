{
  cuda-library-samples-src,
  cudaAtLeast,
  cuda_cudart,
  cuda_culibos,
  lib,
  libnpp_plus,
  mkSamples,
}:
let
  # Not one of these five programs takes a path on the command line: each opens its images through a
  # `Path` constant compiled into it and writes its results back beside them -- the directory
  # `dataDir` names below -- and the four whose `Path` reaches upward are run from the `build`
  # subdirectory upstream's instructions leave you in.
  #
  # Only the *input* files are staged; upstream's expected results are checked in beside them, and
  # staging those would make every `expectedOutputs` entry true before the program ran. Measured
  # here, before this file named any data: four of these five ran against an empty directory, opened
  # not one input, and exited 0 with their tests green.
  testArgs = {
    # The same program as `NPP/batchedLabelMarkersAndCompression`, ported to the NPP+ namespace, and
    # it reads and writes exactly the same names from `../images/`. `-b` is parsed into
    # `params.numofbatch` and then never read: every loop runs to `NUMBER_OF_IMAGES`, which is 5, so
    # all five staged inputs contribute without being asked for.
    "NPP+/batchedLabelMarkersAndCompression".batchedLabelMarkersAndCompression = {
      workSubdir = "build";
      dataDir = "images";
      dataFiles = [
        "lena_512x512_8u.raw"
        "CT_skull_512x512_8u.raw"
        "PCB_METAL_509x335_8u.raw"
        "PCB2_1024x683_8u.raw"
        "PCB_1280x720_8u.raw"
      ];
      # Three results per input: the label markers, their compressed renumbering, and the batched form
      # of the markers. The sample also names `*_CompressedMarkerLabelsUFBatch_*` files in its sources
      # and does not write them, so those are not expected here.
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

    # The odd one out, and the reason none of the names below has a slash in it. This project's `Path`
    # is `"../images"` with no trailing separator -- its four siblings all have one -- and it builds
    # every file name by concatenating that constant with a bare name, so what it actually opens is
    # `../imagesDistanceSampler_512x512_8u.raw`. Staged under any other name the program opens
    # nothing, reports "Input file load failed." and still exits 0. This is the same class of upstream
    # defect as nvJPEG's `-i` needing a trailing slash, arrived at from the other side: there the
    # caller can supply the separator, here it is compiled in and the file has to be put where the
    # program looks.
    #
    # It also does not read the two images checked in under its own `images` directory. The five it
    # names are in its siblings' -- `floodFill/images` and `watershedSegmentation/images` hold all
    # five, byte for byte identical -- so one of those is named here.
    "NPP+/distanceTransform".DistanceTransform = {
      workSubdir = "build";
      dataFiles = lib.listToAttrs (
        map
          (
            name: lib.nameValuePair "images${name}" "${cuda-library-samples-src}/NPP+/floodFill/images/${name}"
          )
          [
            "DistanceSampler_512x512_8u.raw"
            "DistanceSampler_512x512_Inverted_8u.raw"
            "SignedCircle_256x206_64f.raw"
            "SignedCircle_256x206_Inverted_64f.raw"
            "SignedLith_554x554_32f.raw"
          ]
      );
      # Twelve results, and the same missing separator applies to every one of them: the unsigned
      # transform of the two sampler images as 64f and as 16u, the signed transform of the two circles
      # likewise, and four for the lithology image -- 64f, 16u, and the Voronoi indices and relative
      # Manhattan distances that only the signed path produces.
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

    # The only one of the five whose `Path` is `images/` rather than `../images/`, so it runs from the
    # root of the working tree instead of a subdirectory of it.
    #
    # Staged and then withdrawn: the input is named here so that the day the problem below is fixed
    # this is a real run rather than an empty directory again, but the run itself does not survive.
    # Measured against libnpp_plus 0.10.0.0 on an RTX 4090, on the CUDA 12.6 and 12.9 package sets
    # alike, with the input above and nothing else in the tree: the program generates and compresses
    # its label markers correctly ("compressed label count is 268"), then
    # `nppPlusV::nppiCompressedMarkerLabelsUFContoursGenerateGeometryLists_C1R_Ctx` fills the geometry
    # list with garbage -- it prints `nID 1 Cnt 0 BB 0 0 1592984048 21892`, a bounding box of
    # uninitialised memory -- and the walk over that list segfaults, after writing three of the five
    # files the sources name.
    #
    # `NPP/findContour`, the same program against plain NPP, used to be the control here: it decoded
    # the byte-for-byte identical image and wrote all four of its outputs, which is what showed that
    # neither the data nor this machine was at fault. That control no longer holds. Against the
    # 2025-10-09 samples the plain-NPP version fails the same way, more quietly -- it skips its
    # geometry output and prints a label count which changes between runs on identical input -- and
    # is marked broken in `libnpp-samples` for exactly that. The two now corroborate each other
    # rather than one vouching for the other.
    "NPP+/findContour".findContour = {
      dataDir = "images";
      dataFiles = [ "CircuitBoard_2048x1024_8u.raw" ];
      problems.nppPlusContourGeometryListsGarbage = {
        kind = "broken";
        message =
          "Sample NPP+/findContour segfaults walking the contour geometry lists produced by"
          + " nppPlusV::nppiCompressedMarkerLabelsUFContoursGenerateGeometryLists_C1R_Ctx, which"
          + " returns uninitialised bounding boxes (nID 1 Cnt 0 BB 0 0 1592984048 21892). Measured"
          + " against libnpp_plus 0.10.0.0 on the CUDA 12.6 and 12.9 package sets on an RTX 4090,"
          + " with the project's own CircuitBoard_2048x1024_8u.raw staged; this package set has"
          + " ${libnpp_plus.version}. The measured version is written out rather than interpolated"
          + " so that a bump makes the two disagree, which is the reader's cue that this was"
          + " established against something else. NPP/findContour, the same program against plain"
          + " NPP, fails the same way against the current samples: it skips its geometry output and"
          + " prints a compressed-label count which varies between runs on identical input."
          + " Upstream:"
          + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/NPP+/findContour";
      };
    };

    # Two three-channel images, filled five ways: the rainbow chart by seed, by gradient, and by
    # gradient with a boundary, and the seabed sampler by range and by range with a boundary.
    "NPP+/floodFill".floodFill = {
      workSubdir = "build";
      dataDir = "images";
      dataFiles = [
        "RainbowChart_RGB_C3_1024x445_8u.raw"
        "SeabedSampler_RGB_C3_675x1024_8u.raw"
      ];
      expectedOutputs = [
        "RainbowChart_RGB_C3_Fill_8Way_1024x445_Dev_8u.raw"
        "RainbowChart_RGB_C3_Fill_8Way_Gradient_1024x445_Dev_8u.raw"
        "RainbowChart_RGB_C3_Fill_8Way_Gradient_Boundary_1024x445_Dev_8u.raw"
        "SeabedSampler_RGB_C3_Fill_8Way_Range_675x1024_Dev_8u.raw"
        "SeabedSampler_RGB_C3_Fill_8Way_Range_Boundary_675x1024_Dev_8u.raw"
      ];
    };

    # Unlike `NPP/watershedSegmentation`, this one parses no `-b`: it names three images and its loops
    # run to its own `NUMBER_OF_IMAGES`, so all three staged inputs contribute with no arguments.
    # Four results each -- the segments, their boundaries, the two composited, and the compressed
    # segment labels.
    "NPP+/watershedSegmentation".watershedSegmentation = {
      workSubdir = "build";
      dataDir = "images";
      dataFiles = [
        "CT_skull_512x512_8u_Gray.raw"
        "Rocks_512x512_8u_Gray.raw"
        "Corn_614x461_8u_Gray.raw"
      ];
      expectedOutputs = [
        "CT_skull_Segments_8Way_512x512_8u.raw"
        "Rocks_Segments_8Way_512x512_8u.raw"
        "Corn_Segments_8Way_614x461_8u.raw"
        "CT_skull_SegmentBoundaries_8Way_512x512_8u.raw"
        "Rocks_SegmentBoundaries_8Way_512x512_8u.raw"
        "Corn_SegmentBoundaries_8Way_614x461_8u.raw"
        "CT_skull_SegmentsWithContrastingBoundaries_8Way_512x512_8u.raw"
        "Rocks_SegmentsWithContrastingBoundaries_8Way_512x512_8u.raw"
        "Corn_SegmentsWithContrastingBoundaries_8Way_614x461_8u.raw"
        "CT_skull_CompressedSegmentLabels_8Way_512x512_32u.raw"
        "Rocks_CompressedSegmentLabels_8Way_512x512_32u.raw"
        "Corn_CompressedSegmentLabels_8Way_614x461_32u.raw"
      ];
    };
  };
in
mkSamples {
  component = libnpp_plus;
  manifestPath = ./samples.json;
  subtrees = [ "NPP+" ];
  buildInputs = [
    cuda_cudart
  ]
  # Every project here looks for `culibos`, which moved out of `cuda_cudart` into a component of its
  # own in CUDA 13, and CMake refuses to generate without it. Gated on the toolkit version rather
  # than on availability, so that a component which is unavailable on a CUDA 13 set explains itself
  # through `mkSamples` instead of being silently dropped.
  ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];
  inherit testArgs;

  # Every project in this subtree opens with the same two `find_path` calls and hard-errors if
  # either fails. `npp.h` sits at the root of libnpp_plus's include output and is found through
  # CMAKE_PREFIX_PATH; `nppPlus.h` sits one directory down, in `include/nppPlus`, which CMake does
  # not search -- the call passes no PATH_SUFFIXES, and its hard-coded hints are all `/usr` paths --
  # so configuring stops with "Could not find nppPlus.h" on all five projects. Setting the cache
  # variable the `find_path` would have populated is what makes them configure; it is a family rule
  # rather than a `sampleArgs` entry because it is the shared preamble, not any one project, that
  # needs it.
  #
  # The second rewrite is the same kind of thing. Every project calls the NPP+ entry points through
  # the `nppPlusV` namespace and nothing guards those calls, but the header only opens that namespace
  # under `#ifdef NPP_PLUS`, which `nppPlus.h` defines only when `NPP_PLUS_ENABLE` is defined. The
  # projects define `NPP_PLUS_ON` instead, so against the libnpp_plus Nixpkgs ships every one of them
  # fails to compile with `name followed by "::" must be a class or namespace name`. The two spellings
  # are upstream's, in two repositories which drifted apart; defining the one the shipped header reads
  # is what turns these back into a build of NPP+ rather than of nothing.
  sampleArgsFor = sampleRoot: {
    cmakeFlags = [
      (lib.cmakeFeature "NPP_PLUS_HEADER_PATH" "${lib.getInclude libnpp_plus}/include/nppPlus")
    ];
    postPatch = ''
      substituteInPlace ${sampleRoot}/CMakeLists.txt \
        --replace-fail '-DNPP_PLUS_ON' '-DNPP_PLUS_ENABLE'
    '';
  };
}
