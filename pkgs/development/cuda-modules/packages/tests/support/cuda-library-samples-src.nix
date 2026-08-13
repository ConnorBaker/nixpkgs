# The source for NVIDIA's CUDALibrarySamples, shared by every component which draws its samples
# from that repository so we fetch it once rather than once per component.
#
# Unlike `cuda-samples`, this repository is untagged and rolling: there is nothing upstream to
# pin against except a commit, and no changelog describing which toolkit versions a given commit
# supports. Revisions are therefore keyed by their commit date, which is the only thing about them
# that is both stable and meaningful to a reader.
#
# More than one revision is pinned because a single one cannot serve every CUDA package set. The
# repository tracks the newest toolkit and does not keep the older ones building: at 2025-10-09 the
# whole cuBLAS subtree requires CUDA 13.0, for the measured reason `libcublas-samples` sets out where
# it selects its revision. Pinning the package set back to suit cuBLAS would be worse than the
# disease, because the same bump is what unblocked cuDSS's newer projects and what drops the
# `<cal.h>` include that made cuBLASMp and cuSOLVERMp unbuildable here at all.
#
# So the revision is chosen per component rather than per package set: `mkSamples` takes a `src`,
# every component defaults to the newest revision, and a component which cannot use it says so
# where its samples are wired up, with the measurement that forced it. `cuda-samples.nix` pins two
# tags for the same reason and gates its patches on both axes -- which sample revision, and which
# toolkit -- rather than conflating them.
#
# Each revision carries its own key on `passthru.revision`. A component's manifest is selected by
# that key rather than named a second time by hand, so a component cannot end up checking a
# manifest generated from one revision against the checkout of another.
#
# This is the only pin of that repository in the package set. `tests/cuda-library-samples` carried a
# second one, written in base32, which converted to the same hash -- so the two agreed, and a bump
# which updated one of them would have gone unnoticed rather than conflicting.
{
  fetchFromGitHub,
  lib,
}:
let
  # pins :: { <commit date> = { rev = String; hash = String; }; }
  #
  # Delete a pin once no component selects it: an unused one is a fetch nobody checks, and the
  # manifests generated from it go stale without anything noticing, because the drift check only
  # ever compares a manifest against the checkout a component actually builds.
  pins = {
    "2025-10-09" = {
      rev = "a94482ebecf8b16d5b83ab276b7db3a84979f0e5";
      hash = "sha256-v1MK/XaOP+sj8DdGYQtrfME/RKpXiuQQu4cBfHGjsZg=";
    };
    # Retained for cuBLAS on CUDA 12, which the revision above cannot build. Nothing else selects it.
    "2025-01-27" = {
      rev = "e57b9c483c5384b7b97b7d129457e5a9bdcdb5e1";
      hash = "sha256-dEzEK6P0lQcV6WEeayuMalYavnwYsp5VA1WhVbVTJzw=";
    };
  };

  # The newest pin, which is what a component gets unless it asks otherwise. Sorted rather than
  # named a second time, so adding a pin cannot leave the default pointing at the previous one --
  # and sorted rather than "declared first", because an attribute set has no order to declare.
  defaultRevision = lib.last (lib.naturalSort (lib.attrNames pins));

  fetchRevision =
    revision:
    fetchFromGitHub {
      # Named, rather than left as fetchFromGitHub's default: this is an attribute of the package
      # set, and a user querying it would otherwise be shown a package called `source`. The revision
      # is part of the name because two of these can be in one build closure at once.
      name = "cuda-library-samples-src-${revision}";
      owner = "NVIDIA";
      repo = "CUDALibrarySamples";
      inherit (pins.${revision}) rev hash;

      passthru = {
        # Which revision this is, so that a component selecting a source selects the manifest
        # generated from it by the same token rather than by repeating the date.
        inherit revision;
        # Every pin, reachable from any of them, so a component which needs an older checkout can
        # ask for it by date. Selecting one is a decision that belongs next to the measurement which
        # forced it, which is the component's own `package.nix`.
        revisions = byRevision;
      };

      meta = {
        description = "Source of NVIDIA's CUDA library samples (${revision})";
        homepage = "https://github.com/NVIDIA/CUDALibrarySamples";
        # The repository is BSD-3-Clause throughout. The samples built from it are not: they link
        # against a redistributable component and take their license from it, as does anything which
        # runs them.
        license = lib.licenses.bsd3;
        teams = [ lib.teams.cuda ];
      };
    };

  byRevision = lib.genAttrs (lib.attrNames pins) fetchRevision;
in
byRevision.${defaultRevision}
