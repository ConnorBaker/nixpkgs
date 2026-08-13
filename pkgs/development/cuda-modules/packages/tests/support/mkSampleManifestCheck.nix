# Verifies a component's sample manifest against the sample checkout it was generated from.
#
# `buildSample` can only check the projects it is told about: declared executables against produced
# executables, in both directions. That catches a rename or a removal inside a known project, but an
# upstream project which is simply *added* would go untested with nothing to notice it. This closes
# that direction by rescanning the expected subtrees and requiring the manifest to account for
# everything found, and for everything recorded to still exist.
#
# It is a comparison rather than a set of rules. `manifest.py generate` already decides every rule
# there is -- which directories are projects, which program lists survive, how the file is laid out
# -- so the check regenerates the manifest from the checkout and requires it to equal the one
# checked in, byte for byte, with `testers.testEqualContents`. Writing the rules out a second time
# here made this a second implementation which had to be kept in agreement with the first, and the
# agreement was the one thing nothing tested.
#
# The regenerated manifest is also what `passthru.updateScript` copies into place, so the file a
# maintainer commits and the file this compares against are the same bytes from the same command.
# Regenerate with `nix-shell maintainers/scripts/update.nix --argstr path cudaPackages.tests`, or
# narrow the path to one component's samples.
#
# It checks no program name, and cannot: which executables a project builds depends on the component
# and the inputs it is built with, not on the checkout. `buildSample` answers that, against the
# binaries it produced or -- for a project which does not compile here -- against CMake's file API
# through `passthru.certifyPrograms`. The division is exact: this owns the set of projects, that owns
# the contents of each.
#
# Needs no GPU and no component, so it runs anywhere.
{
  _experimental-update-script-combinators,
  cudaMajorMinorVersion,
  cudaNamePrefix,
  lib,
  python3,
  runCommand,
  testers,
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
  # It arrives from the caller, and pointedly not from the manifest, even though the two must agree.
  # A manifest which supplied the subtree list it was regenerated over would be checking itself:
  # deleting a subtree from it -- and with it every project under that subtree -- would leave a
  # manifest that still matched, because nothing would go looking for what was dropped. Narrowing
  # coverage therefore means editing the component's package.nix as well, which is a diff a reviewer
  # will read very differently from a change to a generated file.
  subtrees,
}:
let
  inherit (component) pname;

  # The subtrees as `manifest.py` takes them: the trailing arguments of `generate`.
  subtreeArguments = lib.escapeShellArgs subtrees;

  checkName = "${cudaNamePrefix}-${pname}-sample-manifest-check";

  # Attribute paths from the top level, which is what both `nix-build -A` and `update.nix` take --
  # so this needs the name of the package set, not the prefix its derivations are named with.
  # Derived from the version rather than stated, because a component's samples exist once per set
  # and each writes its own manifest: `libcublas-samples` keeps one per pinned revision, so the file
  # this regenerates is not the same file on every set.
  #
  # `update.nix` is pointed at this check, which is where `updateScript` lives; `nix-build` is
  # pointed at the manifest hanging off it, which is the thing with an output to copy.
  checkAttr =
    "cudaPackages_${lib.replaceStrings [ "." ] [ "_" ] cudaMajorMinorVersion}"
    + ".tests.${pname}-samples.manifest";
  regeneratedAttr = "${checkAttr}.regenerated";

  # Asked here rather than left to the comparison. `dump_manifest` writes the subtrees it is handed,
  # so a manifest recording a different set already fails below -- but it fails as one line of a diff
  # among possibly many, and this is the one line whose meaning is not "upstream changed": it means
  # the manifest and the component disagree about what the manifest is for. Eager, so it is answered
  # before anything is built, and on evaluation rather than in a log.
  recordedSubtrees = (lib.importJSON manifest).subtrees or [ ];

  regenerated =
    runCommand "${checkName}-regenerated"
      {
        pname = "${checkName}-regenerated";
        inherit (component) version;
        nativeBuildInputs = [ python3 ];
        meta = {
          description = "Regenerate ${pname}'s sample manifest from the checkout it describes";
          # Deliberately not narrowed to the component's platforms, unlike the check below. This
          # scans a source tree with Python and never mentions the component, and it is what
          # `updateScript` builds -- so narrowing it would mean a maintainer regenerating manifests
          # could only regenerate the ones whose component happens to have a release for the host
          # they are sitting at. `libcudss` has no aarch64 release on CUDA 13.3, and with the
          # component's platforms here `nix-build -A` of this failed on the availability assert:
          # `update.nix` stops on that, so one component with no local release halted the rest.
          # There is no cost to the wider set, because only `passthru.tests` is queued by CI and this
          # is not one.
          license = src.meta.license;
          teams = [ lib.teams.cuda ];
        };
      }
      ''
        set -euo pipefail
        # stdout is the manifest and stderr names any project whose program list could not be
        # carried forward, which is the one thing a regeneration cannot supply. It is not an error
        # here -- there would be nothing to compare against, and nothing to write -- so it is left in
        # the log, and `mkSamples` refuses to evaluate the manifest that results.
        python3 ${./buildSample/manifest.py} generate --merge ${manifest} ${src} ${subtreeArguments} > "$out"
      '';
in
assert lib.assertMsg (subtrees != [ ]) (
  "${pname}: mkSampleManifestCheck was given no sample subtrees, so it would rescan nothing and the"
  + " manifest would be checked against an empty checkout; declare the subtrees this component"
  + " covers where its samples are wired up"
);
assert lib.assertMsg (lib.sort lib.lessThan recordedSubtrees == lib.sort lib.lessThan subtrees) (
  "${pname}: the sample manifest records subtrees ${lib.concatStringsSep ", " recordedSubtrees} but"
  + " is checked against ${lib.concatStringsSep ", " subtrees}; the subtrees a manifest is"
  + " regenerated over are declared by the component, so a manifest cannot narrow its own coverage"
);
(testers.testEqualContents {
  assertion = "${cudaNamePrefix} ${pname} sample manifest describes its checkout";
  expected = manifest;
  actual = regenerated;
  postFailureMessage =
    "The manifest no longer describes ${src}. Regenerate it with"
    + " `nix-shell maintainers/scripts/update.nix --argstr path ${checkAttr}`, or by hand with"
    + " `manifest.py generate --merge <manifest> <checkout> ${subtreeArguments}`. A project the"
    + " manifest has never recorded has no program list to carry forward and so appears with none:"
    + " build its `passthru.certifyPrograms`, which fails naming exactly what CMake builds. No"
    + " program name was compared here -- which executables a project builds depends on the"
    + " component it is built against, so that is `buildSample`'s question, not this one's.";
}).overrideAttrs
  (prevAttrs: {
    # `testEqualContents` names its result after the assertion and nothing else; see the note beside
    # `mkTester`'s `pname`. This is what a user writes in `config.problems.handlers`.
    pname = checkName;
    inherit (component) version;

    passthru = prevAttrs.passthru or { } // {
      # The manifest this checkout implies, kept where it can be built and read on its own -- which
      # is what the update script does with it, and what anyone comparing by hand wants.
      inherit regenerated subtrees;

      # `copyAttrOutputToFile` builds that attribute and copies its output over the checked-in file.
      # `update.nix` turns the path below into the one in the working tree rather than a store path,
      # which is why the manifest is passed to this file as a path and not as a string.
      updateScript = _experimental-update-script-combinators.copyAttrOutputToFile regeneratedAttr manifest;
    };

    meta = prevAttrs.meta or { } // {
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
  })
