{
  libcurand,
  mkSamples,
}:
mkSamples {
  component = libcurand;
  subtrees = [ "cuRAND" ];
}
