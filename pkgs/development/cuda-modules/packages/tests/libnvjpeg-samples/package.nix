{
  cuda-library-samples-src,
  cudaAtLeast,
  cuda_cudart,
  cuda_culibos,
  lib,
  libnpp,
  libnvjpeg,
  mkSamples,
}:
let
  # The JPEGs upstream ships in each project's `input_images`. They are a mix of grayscale, 4:4:4 and
  # 4:2:0, which is what makes decoding all of them worth more than decoding one; every project's
  # directory holds the same names, and every name is in `expectedOutputs` so that a decoder which
  # skipped the grayscale one leaves a gap.
  inputImageNames = [
    "cat"
    "cat_baseline"
    "cat_grayscale"
    "img1"
    "img2"
    "img3"
    "img4"
    "img5"
    "img6"
    "img7"
    "img8"
    "img9"
  ];

  # `-i` must end in a separator. These samples concatenate the directory and the file name without
  # one -- `input_imagesimg5.jpg` -- so a path without the trailing slash makes every image
  # unopenable, and the sample then reports "No valid images left in the input list" and exits 1.
  # Upstream's own examples are all written `-i ../input_images/`.
  inputImagesOf = project: "${cuda-library-samples-src}/nvJPEG/${project}/input_images/";

  # The decoders write one BMP per input into the directory given to `-o`, which they do not create.
  decoderArgs = project: {
    args = [
      "-i"
      (inputImagesOf project)
      "-o"
      "output"
    ];
    expectedOutputs = map (name: "output/${name}.bmp") inputImageNames;
  };

  # The resizers re-encode to JPEG instead, and take the size and quality upstream's README passes.
  resizeArgs = project: {
    args = [
      "-i"
      (inputImagesOf project)
      "-o"
      "output"
      "-q"
      "85"
      "-rw"
      "512"
      "-rh"
      "512"
    ];
    expectedOutputs = map (name: "output/${name}.jpg") inputImageNames;
  };

  # `nvjpegEncoderParamsCopyHuffmanTables` was removed in the CUDA 13 nvJPEG, and this sample is the
  # only one which calls it -- it copies the source image's Huffman tables onto the watermarked
  # output so the re-encode matches the original's entropy coding.
  #
  # Measured across every package set by searching nvjpeg's own headers: 12.6 (12.3.3.54), 12.8
  # (12.3.5.92) and 12.9 (12.4.0.76) each declare it once, while 13.0 (13.0.1.86), 13.1, 13.2 and
  # 13.3 (13.2.0.21) declare it nowhere -- against a control of twenty-odd `nvjpegEncoderParams*`
  # hits in all seven, so the search was reading the right header. Hence a maximum rather than a
  # `meta.problems`: the sample is fine, and builds, on everything up to 12.9.
  sampleArgs."nvJPEG/Image-Resize-WaterMark".maxCudaVersion = "12.9";

  # Stated by the project itself rather than measured from a symbol: its CMakeLists opens with
  # `find_package(CUDAToolkit 12.9 REQUIRED)`, so on an older package set CMake stops before it
  # defines a target -- "Could NOT find CUDAToolkit: Found unsuitable version 12.6.85, but required
  # is at least 12.9" -- and the sample cannot be configured, let alone built.
  #
  # It is the only versioned `find_package` in the subtrees any component covers, apart from cuDSS's
  # (which has its own entry) and cuTENSOR's `find_package(CUDA 12.0)`, which every package set here
  # satisfies. Found by `sample-programs`, which configures each project and so sees a requirement
  # that stops the configure; nothing else here had looked, and the sample was claimed available on
  # 12.6 and 12.8 while being unbuildable on both.
  sampleArgs."nvJPEG/nvJPEG-Encoder-MultipleInstances".minCudaVersion = "12.9";

  testArgs = {
    "nvJPEG/nvJPEG-Decoder".nvjpegDecoder = decoderArgs "nvJPEG-Decoder";

    "nvJPEG/nvJPEG-Decoder-Backend-ROI".nvJPEGROIDecode = decoderArgs "nvJPEG-Decoder-Backend-ROI" // {
      # The region of interest is the point of this sample -- without `-roi` it decodes whole images
      # exactly as `nvjpegDecoder` does -- and 64x64 is the region upstream's README shows.
      args = (decoderArgs "nvJPEG-Decoder-Backend-ROI").args ++ [
        "-roi"
        "0,0,64,64"
      ];
    };

    # This project ships no images of its own; upstream's README runs it against the plain decoder's,
    # which is why a neighbour's directory is named here.
    "nvJPEG/nvJPEG-Decoder-MultipleInstances".nvJPEGDecMultipleInstances = decoderArgs "nvJPEG-Decoder";

    "nvJPEG/Image-Resize".imageResize = resizeArgs "Image-Resize";

    "nvJPEG/Image-Resize-WaterMark".imageResizeWatermark = resizeArgs "Image-Resize-WaterMark" // {
      # The watermark is opened as the bare relative path `NVLogo.jpg`, with no option to say where
      # it is, so it has to be in the working directory. Without it the sample prints "Cannot open
      # watermark image", writes nothing, and exits 1.
      dataFiles."NVLogo.jpg" = "${cuda-library-samples-src}/nvJPEG/Image-Resize-WaterMark/NVLogo.jpg";
    };
  };
in
mkSamples {
  component = libnvjpeg;
  manifestPath = ./samples.json;
  subtrees = [ "nvJPEG" ];
  buildInputs = [
    cuda_cudart
    libnpp
  ]
  # Three of these projects end their link line with `find_library(CULIBOS culibos ...)`, and CMake
  # refuses to generate when it comes back NOTFOUND: "The following variables are used in this
  # project, but they are set to NOTFOUND: CULIBOS". Through CUDA 12 `libculibos.a` ships inside
  # `cuda_cudart`, which these already have; CUDA 13 moved it into a component of its own. Gated on
  # the toolkit version, as `cuda-samples.nix` gates the same input.
  ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];
  inherit sampleArgs testArgs;
}
