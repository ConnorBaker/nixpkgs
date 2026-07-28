{
  cuda-library-samples-src,
  cuda_cudart,
  libnvtiff,
  mkSamples,
}:
let
  sampleArgs = {
    # `std::vector<uint8_t> image_out_h(size)` with no `#include <vector>`: the source includes
    # `<sstream>` and `<string>` and relies on one of them dragging the header in, which the
    # libstdc++ Nixpkgs ships does not do. g++ says so itself, and suggests the same one-line fix:
    #   error: 'vector' is not a member of 'std'
    #   note: 'std::vector' is defined in header '<vector>'; this is probably fixable by adding
    #         '#include <vector>'
    # Nothing about this depends on the toolkit -- it is a missing include in host C++ -- so it is
    # patched rather than given a CUDA version boundary it does not have.
    "nvTIFF/nvTIFF-Decode-Image-ROI".postPatch = ''
      substituteInPlace nvTIFF/nvTIFF-Decode-Image-ROI/nvtiff_decode_image_roi.cpp \
        --replace-fail '#include <string>' '#include <string>
      #include <vector>'
    '';

    # The same class of defect in the sibling project, and found the same way -- g++ naming each
    # identifier it cannot resolve. It calls `memcmp`, `memcpy` and `strdup` without `<string.h>`,
    # and `fmax` and `fmin` without `<math.h>`, relying on one of the headers it does include to drag
    # them in; the libstdc++ Nixpkgs ships does not:
    #   error: 'memcmp' was not declared in this scope
    #   error: 'strdup' was not declared in this scope
    #   error: 'fmax' was not declared in this scope
    # The C spellings are used rather than <cstring>/<cmath> to match the file's own style, which
    # includes <stdio.h> and <stdlib.h>. As above, nothing here depends on the toolkit.
    "nvTIFF/nvTIFF-Decode-Encode".postPatch = ''
      substituteInPlace nvTIFF/nvTIFF-Decode-Encode/nvtiff_example.cpp \
        --replace-fail '#include <stdlib.h>' '#include <stdlib.h>
      #include <string.h>
      #include <math.h>'
    '';
  };

  # All three of these require `-f <TIFF_FILE>` and do nothing without it: `nvtiff_decode_image_roi`
  # prints "Please specificy tiff file", goes on to use the empty name anyway and dies with
  # "nvtiff error code 2 ... line 232", and its two neighbours print their usage and exit non-zero.
  #
  # The file is named as a store path rather than staged, because each of them derives its output
  # name from the *basename* of what it was given -- `write_image` takes the substring after the last
  # separator and then strips the extension -- so a store path yields exactly the
  # `bali_notiles_nvtiff_out_0` a relative path would.
  tiffOf = project: "${cuda-library-samples-src}/nvTIFF/${project}/images/bali_notiles.tif";

  # The one 725x489 image upstream ships, decoded into one PNM per subfile. It is RGB
  # (`samples_per_pixel` 3), which is the branch of `write_image` that appends `.ppm`; `.pgm` is the
  # grayscale branch, and this file is not grayscale.
  decodedImageName = "bali_notiles_nvtiff_out_0.ppm";
in
mkSamples {
  component = libnvtiff;
  manifestPath = ./samples.json;
  subtrees = [ "nvTIFF" ];
  buildInputs = [ cuda_cudart ];
  inherit sampleArgs;

  # Writing is off by default in all three: given only `-f` they decode into device memory, print a
  # timing and exit 0 having produced nothing a test could look at. `--decode-out` is what puts the
  # decoded raster on disk, and it is spelled with `=` because the option is declared
  # `optional_argument`: a separate `1` would be consumed by the sample's own hand-rolled lookahead
  # at `argv[optind]` rather than by getopt, which works but reads as though it were an operand.
  testArgs = {
    "nvTIFF/nvTIFF-Decode-Encode".nvTiff_example = {
      args = [
        "-f"
        (tiffOf "nvTIFF-Decode-Encode")
        # Encoding is half of what this project is named for and is off by default; without `-E` this
        # is the same decode its GeoTIFF neighbour performs. `--encode-out` then writes the
        # LZW-compressed result, under a file name the sample hard-codes.
        "-E"
        "--encode-out"
        "--decode-out=1"
      ];
      expectedOutputs = [
        decodedImageName
        "outFile.tif"
      ];
    };

    # This project ships no image of its own -- it is the only one of the three whose directory has
    # no `images` -- so the decode/encode project's is named here, the way
    # `nvJPEG-Decoder-MultipleInstances` borrows its neighbour's.
    "nvTIFF/nvTIFF-Decode-Image-ROI".nvtiff_decode_image_roi = {
      args = [
        "-f"
        (tiffOf "nvTIFF-Decode-Encode")
        # The region of interest is the point of this sample: without `-roi` it decodes the whole
        # image, which its two neighbours already do. Offset as well as cropped, so that a decoder
        # which ignored the offset would not produce the same bytes as one which honoured it.
        "-roi"
        "100,100,256,256"
        # Unlike the other two, this one writes into a directory named on the command line and does
        # not create it. `expectedOutputs` creates it before the run; without `-o` at all the sample
        # sets `write_output` false and writes nothing.
        "-o"
        "output"
      ];
      expectedOutputs = [ "output/${decodedImageName}" ];
    };

    "nvTIFF/nvTIFF-GeoTIFF-Decode".nvtiff_geotiff_decode = {
      args = [
        "-f"
        (tiffOf "nvTIFF-GeoTIFF-Decode")
        "--decode-out=1"
      ];
      # Into the working directory: this sample's `write_image` has no output-directory parameter.
      expectedOutputs = [ decodedImageName ];
    };
  };
}
