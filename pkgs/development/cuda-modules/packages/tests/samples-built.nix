# Compiles every sample which is available on this platform and package set.
#
# `sample-manifests` proves the manifest still describes the upstream checkout and `sample-programs`
# proves each project's declared executables are the ones CMake builds, but neither compiles
# anything: the first reads a source tree and the second stops after configure. Without this
# aggregate a sample which stops *compiling* is invisible to CI, because the only things which refer
# to a sample are the tests which run it, and those need a GPU.
#
# The samples are reached through those tests rather than read out of an attribute beside them: a
# test carries its tester, a tester carries its sample, and several tests share one sample -- a
# project which builds two executables has two tests -- so they are deduplicated by the manifest key
# each sample carries.
#
# Samples are filtered on `meta.available` rather than built wholesale: a few are marked broken with
# a measured `meta.problems` entry (an upstream API change with no version here that compiles, for
# instance), and forcing those would make this aggregate impossible to keep green.
#
# The components are named rather than discovered by filtering `cudaPackages`; see the note in
# `sampleComponentNames.nix`, which is where they are named.
#
# No GPU is needed; this is compilation only. Running the programs is what the tests under
# `<component>-samples` do, and those require the `cuda` system feature.
{
  cudaNamePrefix,
  lib,
  linkFarm,
  sampleComponentNames,
  tests,
}:
let
  componentSets = lib.genAttrs sampleComponentNames (componentName: tests.${componentName});

  # knowinglyUnavailable :: { <component>-samples = String; }
  # Components every one of whose samples is unavailable here on purpose, each with the reason.
  #
  # `meta.problems` alone cannot express this. A mistyped `minCudaVersion` which empties a component
  # and a measured judgement that every one of its samples is broken produce exactly the same thing
  # -- `meta.problems` entries on every sample -- so a guard which infers the intent from what it
  # finds cannot tell the accident from the decision, and has to choose which of the two to allow.
  # Declaring it here is the difference: the reason is written down, by name, next to the component
  # it excuses, and everything else which contributes nothing while being available is still wrong.
  #
  # Kept honest from both sides. A name here which this file does not collect, and a component here
  # which does contribute an available sample, both fail the build below -- the second is what turns
  # a declaration into something that expires: the day a component's samples build again, the
  # declaration saying they cannot has to go, rather than staying to excuse the next breakage. The
  # entries are printed on every build, so "we know these are all broken" is in the log of every
  # green run rather than in an attribute nobody opens.
  knowinglyUnavailable = {
    "libcublasmp-samples" =
      "its four pmatmul programs call cublasMpMatmulDescriptorAttributeSet, which the cuBLASMp every"
      + " package set ships does not declare, and the subtree is one CMake project so all nine fail";
    "nvcomp-samples" =
      "both projects are written against the nvCOMP 4.x batched API, and every CUDA package set"
      + " here provides nvCOMP 5.0.0.6, which renamed it";
  };

  # `recurseIntoAttrs` leaves a boolean beside the tests, and the manifest drift check is a test
  # which runs no sample; neither yields one.
  #
  # `sampleKey` and `component` are put on the sample by `mkSamples`, which asserts that
  # `buildSample` forwarded them rather than leaving this file to discover a missing attribute with
  # no indication of who should have set it.
  samplesOf =
    componentTests:
    lib.listToAttrs (
      map (test: lib.nameValuePair test.tester.sample.sampleKey test.tester.sample) (
        lib.filter (test: test ? tester) (lib.filter lib.isDerivation (lib.attrValues componentTests))
      )
    );

  # The component a set of tests exercises, taken from the samples themselves rather than named a
  # second time here, where the two could come to disagree.
  componentOf = componentTests: (lib.head (lib.attrValues (samplesOf componentTests))).component;

  availableSamplesOf =
    componentTests:
    lib.filterAttrs (_: sample: sample.meta.available or false) (samplesOf componentTests);

  components = lib.mapAttrs (_: componentOf) componentSets;

  # One farm per component, then a farm of those, so that two components which happen to name a
  # sample identically cannot collide into a single link.
  perComponent = lib.mapAttrs (
    name: componentTests: linkFarm "${cudaNamePrefix}-${name}" (availableSamplesOf componentTests)
  ) componentSets;

  availableCounts = lib.mapAttrs (
    _: componentTests: lib.length (lib.attrNames (availableSamplesOf componentTests))
  ) componentSets;

  availableCount = lib.foldl' lib.add 0 (lib.attrValues availableCounts);

  # A component which is unavailable here contributes no samples, and legitimately so: cuDSS has no
  # CUDA 13 release, so on those package sets every one of its samples is unavailable for the same
  # reason the component is, and an aggregate which failed over that would be red on half the
  # package sets for no defect. A component which *is* available here and still contributes nothing
  # is the case a total count cannot see -- a mistyped `minCudaVersion` empties one component while
  # the rest keep the total comfortably above zero -- so it is asked per component, and
  # answered against `knowinglyUnavailable` rather than against the samples' own `meta.problems`,
  # which the accident and the decision both produce.
  emptyButExpected = lib.attrNames (
    lib.filterAttrs (
      name: count:
      count == 0 && !(knowinglyUnavailable ? ${name}) && (components.${name}.meta.available or false)
    ) availableCounts
  );

  # A declaration naming something this file does not collect excuses nothing and hides that it
  # excuses nothing: the component it was meant for goes on being checked, and the reason written
  # here goes on looking like it applies to it.
  unknownDeclarations = lib.subtractLists (lib.attrNames componentSets) (
    lib.attrNames knowinglyUnavailable
  );

  # A declaration which is no longer true. Left in place it would silently cover a component which
  # had come back and then broke again, which is the same blindness `emptyButExpected` exists to
  # close, arrived at from the other direction.
  declaredYetContributing = lib.attrNames (
    lib.filterAttrs (name: count: count > 0 && knowinglyUnavailable ? ${name}) availableCounts
  );

  # Printed whether or not anything is wrong, so that a green build states what it was told not to
  # expect anything from, instead of being green partly because it was told to be.
  declarations = lib.concatMapStrings (name: ''
    nixLog ${lib.escapeShellArg "${name} contributes no available sample, by declaration: ${knowinglyUnavailable.${name}}"}
  '') (lib.attrNames knowinglyUnavailable);

  # Taken from the components rather than written out: these compile against a redistributable and
  # are no freer, and no more portable, than it is. Without a license this aggregate evaluated
  # happily with unfree packages disallowed -- which is the Nixpkgs default -- and then failed on
  # something else entirely; without platforms it was scheduled on every system Hydra supports,
  # including those where no component exists at all.
  license = lib.unique (
    lib.concatMap (component: lib.toList component.meta.license) (lib.attrValues components)
  );
  platforms = lib.unique (
    lib.concatMap (component: component.meta.platforms or [ ]) (lib.attrValues components)
  );

  # An aggregate which compiles nothing would go green and prove nothing, which is the failure mode
  # this file exists to close.
  #
  # This is a build failure and not an assertion. An assertion here is thrown by the attribute
  # itself, before `meta` exists, so nothing can filter it: `nix-env` swallows it, and Hydra -- which
  # schedules this on every supported system, since it is the aggregate's own `meta.platforms` that
  # says otherwise -- reports a permanent evaluation error per system rather than a failed build.
  # Being unavailable is expressed above, in `meta`; being wrong is expressed here, in a build log.
  guard =
    lib.optionalString (availableCount == 0) ''
      nixErrorLog "no component contributed an available sample, so this compiled nothing"
      nixErrorLog "components: ${lib.concatStringsSep ", " (lib.attrNames componentSets)}"
      exit 1
    ''
    + lib.optionalString (emptyButExpected != [ ]) ''
      nixErrorLog "available here, yet contributed no sample: ${lib.concatStringsSep ", " emptyButExpected}"
      nixErrorLog "either the requirements of those samples are wrong, or something they are built against is unavailable"
      nixErrorLog "if every one of those samples is knowingly broken, say so in knowinglyUnavailable, with the reason"
      exit 1
    ''
    + lib.optionalString (unknownDeclarations != [ ]) ''
      nixErrorLog "knowinglyUnavailable names ${lib.concatStringsSep ", " unknownDeclarations}, which this aggregate does not collect"
      nixErrorLog "a declaration about a component nothing here builds excuses nothing, and hides that it excuses nothing"
      exit 1
    ''
    + lib.optionalString (declaredYetContributing != [ ]) ''
      nixErrorLog "declared knowingly unavailable, yet contributed a sample: ${lib.concatStringsSep ", " declaredYetContributing}"
      nixErrorLog "the declaration no longer describes those components and must be removed, or it will excuse the next breakage"
      exit 1
    '';
in
(linkFarm "${cudaNamePrefix}-samples-built" perComponent).overrideAttrs (prevAttrs: {
  buildCommand = prevAttrs.buildCommand + declarations + guard;

  passthru = prevAttrs.passthru or { } // {
    inherit
      availableCount
      availableCounts
      emptyButExpected
      knowinglyUnavailable
      perComponent
      ;
  };

  meta = prevAttrs.meta or { } // {
    description = "Compile every available CUDA component sample";
    inherit license platforms;
    teams = [ lib.teams.cuda ];
  };
})
