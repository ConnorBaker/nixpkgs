{
  cudaAtLeast,
  cuda_culibos,
  lib,
  libnpp,
  libnvjpeg,
  mkSamples,
}:
let
  # Upstream concatenates filenames, so the directory argument must end with a slash.
  inputImagesOf = src: project: "${src}/nvJPEG/${project}/input_images/";

  # Each project reads the whole JPEG corpus and writes one file per input basename.
  outputsOf =
    src: project: extension:
    let
      images = lib.filesystem.listFilesRecursive (inputImagesOf src project);
    in
    assert images != [ ];
    map (path: "output/${lib.removeSuffix ".jpg" (baseNameOf path)}.${extension}") images;

  decoderArgs = project: { src, ... }: {
    args = [
      "-i"
      (inputImagesOf src project)
      "-o"
      "output"
    ];
    expectedOutputs = outputsOf src project "bmp";
  };

  resizeArgs = project: { src, ... }: {
    args = [
      "-i"
      (inputImagesOf src project)
      "-o"
      "output"
      "-q"
      "85"
      "-rw"
      "512"
      "-rh"
      "512"
    ];
    expectedOutputs = outputsOf src project "jpg";
  };

in
mkSamples {
  component = libnvjpeg;
  subtrees = [ "nvJPEG" ];
  # culibos moved out of cudart in CUDA 13.
  defaults.buildInputs = [ libnpp ] ++ lib.optionals (cudaAtLeast "13") [ cuda_culibos ];

  # CMake explicitly requires CUDAToolkit 12.9 before defining any targets.
  fixups.nvJPEG.nvJPEG-Encoder-MultipleInstances.expectedFailure =
    if cudaAtLeast "12.9" then
      null
    else
      {
        message = "This project requires CUDAToolkit 12.9 at configuration time.";
        expectedBuilderExitCode = 1;
        expectedBuilderLogEntries = [
          "Could NOT find CUDAToolkit"
          ''required is at least "12.9"''
        ];
      };

  fixups = {
    nvJPEG.nvJPEG-Decoder.invocations = context: {
      nvjpegDecoder = decoderArgs "nvJPEG-Decoder" context;
    };
    nvJPEG.nvJPEG-Decoder-Backend-ROI.invocations = context: {
      nvJPEGROIDecode = decoderArgs "nvJPEG-Decoder-Backend-ROI" context // {
        args = (decoderArgs "nvJPEG-Decoder-Backend-ROI" context).args ++ [
          "-roi"
          "0,0,64,64"
        ];
      };
    };
    # This project borrows the plain decoder input directory.
    nvJPEG.nvJPEG-Decoder-MultipleInstances.invocations = context: {
      nvJPEGDecMultipleInstances = decoderArgs "nvJPEG-Decoder" context;
    };
    nvJPEG.Image-Resize.invocations = context: {
      imageResize = resizeArgs "Image-Resize" context;
    };
    nvJPEG.Image-Resize-WaterMark = {
      # CUDA 13 removed nvjpegEncoderParamsCopyHuffmanTables used by watermarking.
      maxCudaVersion = "12.9";
      invocations = context: {
        imageResizeWatermark = resizeArgs "Image-Resize-WaterMark" context // {
          # NVLogo.jpg is a hard-coded relative path, not a command-line option.
          dataFiles."NVLogo.jpg" = "${context.src}/nvJPEG/Image-Resize-WaterMark/NVLogo.jpg";
        };
      };
    };
  };
}
