{
  cuda_cudart,
  libcurand,
  mkSamples,
}:
mkSamples {
  component = libcurand;
  manifestPath = ./samples.json;
  subtrees = [ "cuRAND" ];
  buildInputs = [ cuda_cudart ];
}
