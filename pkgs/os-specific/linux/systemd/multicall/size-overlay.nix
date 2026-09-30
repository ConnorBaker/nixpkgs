# A crossOverlay of a static package set that builds it for size: -Oz, with fat LTO objects, so that each
# archive carries both regular code and IR, which the final links LTO-link through the linker plugin. (The
# cc-wrapper appends these flags after a package's own.)
final: prev:
let
  withCFlags = flags: prev.stdenvAdapters.withCFlags flags prev.stdenv;
  flags = [
    "-Oz"
    "-flto=auto"
    "-ffat-lto-objects"
  ];
in
{
  stdenv = withCFlags flags;
  # Its symbols-static test trips over the symbols fat LTO objects add.
  libxcrypt = prev.libxcrypt.override { stdenv = withCFlags [ "-Oz" ]; };
  # Its assembly lacks .note.GNU-stack, which linkers take for a request for an executable stack.
  libucontext = prev.libucontext.override { stdenv = withCFlags (flags ++ [ "-Wa,--noexecstack" ]); };
}
