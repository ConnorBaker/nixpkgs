# Read during evaluation, not from a derivation output.
{ }:
builtins.fetchTarball {
  name = "cuda-library-samples-src-2025-10-09";
  url = "https://github.com/NVIDIA/CUDALibrarySamples/archive/a94482ebecf8b16d5b83ab276b7db3a84979f0e5.tar.gz";
  sha256 = "sha256-v1MK/XaOP+sj8DdGYQtrfME/RKpXiuQQu4cBfHGjsZg=";
}
