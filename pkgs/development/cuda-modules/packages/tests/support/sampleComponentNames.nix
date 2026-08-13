# The `<component>-samples` test sets, named once.
#
# One aggregate walks these today -- `samples-built` -- and the list is kept apart from it all the
# same. Checking the manifest and the program lists used to be aggregates of their own, each
# carrying its own copy of this list, and adding a component meant editing three files: missing one
# did not fail, because that aggregate would collect the components it still knew about and report
# success, having quietly stopped covering the new one. Those two are now leaves of each
# component's own test set, where there is nothing to keep in step -- but a list of components is
# the kind of thing a second aggregate grows a copy of, and it only has to be written down once for
# that not to happen.
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
