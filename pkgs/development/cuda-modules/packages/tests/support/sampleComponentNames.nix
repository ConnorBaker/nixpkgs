# The `<component>-samples` test sets, named once.
#
# Three aggregates walk these -- `sample-manifests`, `sample-programs` and `samples-built` -- and each
# carried its own copy of this list. Adding a component then meant editing three files, and missing
# one did not fail: that aggregate would collect the components it still knew about and report
# success, having quietly stopped covering the new one. Each of those files guards against exactly
# that with a vacuity check, and the duplicated list reintroduced it one level up, where the guard
# cannot see it.
#
# Named rather than discovered by filtering `cudaPackages` for a `-samples` suffix. Filtering forces
# every attribute of the package set -- including the deprecated aliases, which warn as they are
# evaluated -- to answer a question about itself, and it silently reports success on an empty result
# if the attribute it filters on is ever renamed. Naming them means adding a component here as well
# as under `tests`, which is one extra line in the same directory.
{ }:
[
  "libcublas-samples"
  "libcublasmp-samples"
  "libcudss-samples"
  "libcufft-samples"
  "libcurand-samples"
  "libcusolver-samples"
  "libcusolvermp-samples"
  "libcusparse-samples"
  "libcusparse_lt-samples"
  "libcutensor-samples"
  "libnpp-samples"
  "libnpp_plus-samples"
  "libnvjpeg-samples"
  "libnvjpeg_2k-samples"
  "libnvtiff-samples"
  "nvcomp-samples"
]
