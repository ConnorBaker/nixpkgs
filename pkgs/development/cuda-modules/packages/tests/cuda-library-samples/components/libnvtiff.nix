{
  libnvtiff,
  mkSamples,
}:
let
  # ROI borrows the decode/encode image. Outputs depend on the input basename, not its directory.
  tiffOf = src: project: "${src}/nvTIFF/${project}/images/bali_notiles.tif";

  # The supplied RGB TIFF produces a PPM; --decode-out=1 explicitly enables writing.
  decodedImageName = "bali_notiles_nvtiff_out_0.ppm";
in
mkSamples {
  component = libnvtiff;
  subtrees = [ "nvTIFF" ];

  fixups = {
    nvTIFF.nvTIFF-Decode-Image-ROI = {
      # The source omits required host C++ includes.
      postPatch = ''
        substituteInPlace "$sampleRoot/nvtiff_decode_image_roi.cpp" \
          --replace-fail '#include <string>' '#include <string>
        #include <vector>'
      '';

      invocations = context: {
        nvtiff_decode_image_roi = {
          args = [
            "-f"
            (tiffOf context.src "nvTIFF-Decode-Encode")
            # Exercise an offset ROI, not the full-image decoding of the sibling examples.
            "-roi"
            "100,100,256,256"
            "-o"
            "output"
          ];
          expectedOutputs = [ "output/${decodedImageName}" ];
        };
      };
    };

    nvTIFF.nvTIFF-Decode-Encode = {
      postPatch = ''
        substituteInPlace "$sampleRoot/nvtiff_example.cpp" \
          --replace-fail '#include <stdlib.h>' '#include <stdlib.h>
        #include <string.h>
        #include <math.h>'
      '';

      invocations = context: {
        nvTiff_example = {
          args = [
            "-f"
            (tiffOf context.src "nvTIFF-Decode-Encode")
            # Enable both encoding and file output; the default only decodes in memory.
            "-E"
            "--encode-out"
            "--decode-out=1"
          ];
          expectedOutputs = [
            decodedImageName
            "outFile.tif"
          ];
        };
      };
    };
    nvTIFF.nvTIFF-GeoTIFF-Decode.invocations = context: {
      nvtiff_geotiff_decode = {
        args = [
          "-f"
          (tiffOf context.src "nvTIFF-GeoTIFF-Decode")
          "--decode-out=1"
        ];
        expectedOutputs = [ decodedImageName ];
      };
    };
  };
}
