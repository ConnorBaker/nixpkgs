# Verifies a component's sample manifest against the sample checkout it was generated from.
#
# `buildSample` can only check the projects it is told about: declared executables against produced
# executables, in both directions. That catches a rename or a removal inside a known project, but an
# upstream project which is simply *added* would go untested with nothing to notice it. This closes
# that direction by rescanning the expected subtrees and requiring the manifest to account for
# everything found, and for everything recorded to still exist.
#
# It checks no program name, and `manifest.py` says so in its own summary. Which executables a
# project builds depends on the component and the inputs it is built with, not on the checkout, so
# it is not a question this can answer from a source tree; `buildSample` answers it, against the
# binaries it produced or -- for a project which does not compile here -- against CMake's file API
# through `passthru.certifyPrograms`. The division is exact: this owns the set of projects, that
# owns the contents of each.
#
# Needs no GPU and no component, so it runs anywhere.
{
  cudaNamePrefix,
  lib,
  python3,
  runCommand,
}:
{
  # The component the manifest belongs to, used for naming and to decide where this is worth
  # running.
  component,
  # The sample checkout the manifest describes.
  src,
  # The checked-in manifest, as a path.
  manifest,
  # Which subtrees of CUDALibrarySamples the manifest is expected to cover, declared by the
  # component's own `tests/<component>-samples/package.nix` and threaded through `mkSamples`.
  #
  # It arrives from the caller, and pointedly not from the manifest, even though `manifest.py check`
  # requires the two to agree. A manifest which supplied the subtree list it was checked against
  # would be checking itself: deleting a subtree from it -- and with it every project under that
  # subtree -- would leave a manifest that still "matches", because nothing would go looking for
  # what was dropped. Narrowing coverage therefore means editing the component's package.nix as
  # well, which is a diff a reviewer will read very differently from a change to a generated file.
  subtrees,
}:
let
  inherit (component) pname;

  # The subtrees as `manifest.py` takes them: the trailing arguments of both its subcommands.
  subtreeArguments = lib.escapeShellArgs subtrees;

  # The invocation which produced the manifest, spelled out from the very `subtrees` it is checked
  # against so that the two cannot drift. It is printed when the check fails -- the one moment
  # anyone wants it -- which is why the component's package.nix says how to regenerate its manifest
  # without writing its subtrees out a second time.
  regenerateCommand = "manifest.py generate --merge samples.json <checkout> ${subtreeArguments}";
in
assert lib.assertMsg (subtrees != [ ]) (
  "${pname}: mkSampleManifestCheck was given no sample subtrees, so it would rescan nothing and the"
  + " manifest would be checked against an empty checkout; declare the subtrees this component"
  + " covers where its samples are wired up"
);
runCommand "${cudaNamePrefix}-${pname}-sample-manifest-check"
  {
    nativeBuildInputs = [ python3 ];
    passthru = {
      # The two facts a reader of a failing log wants next, kept where they can be asked for without
      # rebuilding: which subtrees this was told to cover, and the command which regenerates the
      # manifest for exactly those.
      inherit regenerateCommand subtrees;
    };
    meta = {
      description = "Check that ${pname}'s sample manifest accounts for every upstream project";
      # This scans a source tree with Python and links against nothing, so it is not the component's
      # license which applies here but the sample repository's -- and it would run anywhere. It is
      # restricted to the platforms the component supports all the same: a manifest describing
      # samples which cannot be built here is checked by the package sets where they can be, and
      # without this every CUDA package set contributes a job on platforms with no CUDA at all.
      inherit (component.meta) platforms;
      license = src.meta.license;
      teams = [ lib.teams.cuda ];
    };
  }
  ''
    set -euo pipefail
    manifestPy=${./buildSample/manifest.py}
    if ! python3 "$manifestPy" check ${src} ${manifest} ${subtreeArguments} | tee "$out"; then
      echo "regenerate ${pname}'s manifest with: ${regenerateCommand}" >&2
      exit 1
    fi
  ''
