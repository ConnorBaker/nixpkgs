{
  cuda-library-samples-src,
  cuda_cudart,
  libnvjpeg_2k,
  mkSamples,
}:
let
  # All four of these programs take `-i` and refuse to guess: with no arguments each falls back to
  # `getInputDir`, which looks for a `data` directory beside the executable, finds none in the store,
  # prints "Please specify input directory with encoded images" and exits 1.
  #
  # Unlike nvJPEG next door, `-i` needs no trailing separator here: these read it with
  # `std::filesystem::recursive_directory_iterator` and keep the paths it yields, rather than
  # concatenating the directory and the file name themselves.
  imagesOf = project: "${cuda-library-samples-src}/nvJPEG2000/${project}/images";

  # The three JPEG 2000 codestreams the decoder project ships, one per subdirectory: a 2K lossless,
  # a 2K lossy and a 4K lossy. Each is three-channel, which is the branch of `write_image` that
  # appends `.bmp`; the `.pgm` branch is for single-component images and none of these is one. All
  # three are named, so a decoder which skipped the 4K one leaves a gap.
  decodedImageNames = [
    "2k_lossless"
    "2k_lossy"
    "4k_lossy"
  ];

  # All three decoders share `write_image`, and all three write into the directory given to `-o`,
  # which they do not create. Without `-o` they decode into device memory, print their timings and
  # exit 0 having put nothing on disk.
  decoderArgs = {
    args = [
      "-i"
      (imagesOf "nvJPEG2000-Decoder")
      "-o"
      "output"
      # Logs the GPU and the "3/4 channel images are written out as bmp files" line, so the run says
      # which device it used and what it set out to write.
      "-v"
    ];
    expectedOutputs = map (name: "output/${name}.bmp") decodedImageNames;
  };

  testArgs = {
    "nvJPEG2000/nvJPEG2000-Decoder".nvjpeg2000_decode_sample = decoderArgs;

    # Neither of these two ships images of its own; both are variations on the plain decoder, so both
    # are pointed at its directory, the way `nvJPEG-Decoder-MultipleInstances` borrows its
    # neighbour's next door.
    "nvJPEG2000/nvJPEG2000-Decoder-Pipelined".nvjpeg2k_dec_pipelined = decoderArgs;

    "nvJPEG2000/nvJPEG2000-Decoder-Tile-Partial".nvj2k_decode_tile_partial = decoderArgs // {
      # Partial decoding is what this project is named for, and it is off unless `-da` is given:
      # without it `params.partial_decode` stays false and the program decodes whole images exactly
      # as `nvjpeg2000_decode_sample` does. With this window each output is a 512x512 three-channel
      # BMP -- 786486 bytes rather than the 6220854 of a whole 2K image -- so the two paths are
      # distinguishable by more than both being non-empty.
      args = decoderArgs.args ++ [
        "-da"
        "0,0,512,512"
      ];
    };

    "nvJPEG2000/nvJPEG2000-Encoder".nvjpeg2k_encode = {
      # `-I -q_factor 50` is passed to make the output's *name* deterministic, which it otherwise is
      # not. The encoder builds the file name from its encode settings, and one of them --
      # `params.quality_type` -- is only ever assigned inside the `-q_factor`, `-quantization` and
      # `-psnr` option branches. Given none of them it is read uninitialised, and lands in the name
      # through `std::to_string`. Measured: three runs with no quality option produced
      # `..._qt-1832941808_...`, `..._qt-1763007584_...` and `..._qt860553984_...`, so no
      # `expectedOutputs` entry could ever match twice.
      #
      # `-q_factor` alone is refused -- "Quality can only be used if irreversible transform is
      # enabled" -- so `-I` comes with it, which also selects the `irrevWavelet` half of the name.
      # With both, two runs produced byte-identical names.
      args = [
        "-i"
        (imagesOf "nvJPEG2000-Encoder")
        "-o"
        "output"
        "-I"
        "-q_factor"
        "50"
      ];
      # Every component of this name is a setting above: `qt2` is NVJPEG2K_QUALITY_TYPE_Q_FACTOR,
      # `qv50.000000` the factor as `std::to_string` renders it, `irrevWavelet` from `-I`, `legacy`
      # because `-ht` was not passed, and `blksz64x64` because `-cblk` was not.
      expectedOutputs = [
        "output/TestImage640x480_qt2_qv50.000000_irrevWavelet_legacy_blksz64x64.jp2"
      ];
    };
  };
in
mkSamples {
  component = libnvjpeg_2k;
  manifestPath = ./samples.json;
  subtrees = [ "nvJPEG2000" ];
  buildInputs = [ cuda_cudart ];
  inherit testArgs;
}
