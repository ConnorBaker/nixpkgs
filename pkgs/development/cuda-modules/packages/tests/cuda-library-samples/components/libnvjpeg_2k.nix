{
  libnvjpeg_2k,
  mkSamples,
}:
let
  imagesOf = src: project: "${src}/nvJPEG2000/${project}/images";

  decodedImageNames = [
    "2k_lossless"
    "2k_lossy"
    "4k_lossy"
  ];

  # All decoders use the plain decoder images; -o enables file output and -v reports format/device.
  decoderArgs = { src, ... }: {
    args = [
      "-i"
      (imagesOf src "nvJPEG2000-Decoder")
      "-o"
      "output"
      "-v"
    ];
    expectedOutputs = map (name: "output/${name}.bmp") decodedImageNames;
  };

in
mkSamples {
  component = libnvjpeg_2k;
  subtrees = [ "nvJPEG2000" ];

  fixups = {
    nvJPEG2000.nvJPEG2000-Decoder.invocations = context: {
      nvjpeg2000_decode_sample = decoderArgs context;
    };
    nvJPEG2000.nvJPEG2000-Decoder-Pipelined.invocations = context: {
      nvjpeg2k_dec_pipelined = decoderArgs context;
    };
    nvJPEG2000.nvJPEG2000-Decoder-Tile-Partial.invocations = context: {
      nvj2k_decode_tile_partial = decoderArgs context // {
        # -da enables partial decoding; without it this duplicates the full decoder.
        args = (decoderArgs context).args ++ [
          "-da"
          "0,0,512,512"
        ];
      };
    };
    nvJPEG2000.nvJPEG2000-Encoder.invocations = context: {
      nvjpeg2k_encode = {
        # Both flags are required to avoid uninitialized quality_type in the output filename.
        args = [
          "-i"
          (imagesOf context.src "nvJPEG2000-Encoder")
          "-o"
          "output"
          "-I"
          "-q_factor"
          "50"
        ];
        expectedOutputs = [
          "output/TestImage640x480_qt2_qv50.000000_irrevWavelet_legacy_blksz64x64.jp2"
        ];
      };
    };
  };
}
