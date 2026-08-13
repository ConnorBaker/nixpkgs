# Compiles every sample which is available on this platform and package set.
#
# Building a component's testers already compiles its samples, so this is not the only thing which
# does. What it adds is the question none of them can be asked: whether there were any. A tester
# which stops being built because its sample became unavailable is a failure nowhere -- it is simply
# no longer scheduled -- so a mistyped `minCudaVersion` which empties one component is silent, and a
# change which empties every component leaves a set of jobs that all pass by not existing. The
# guards at the bottom are what this file is for; compiling is how it reaches them.
#
# The samples are reached through the testers which run them rather than read out of an attribute
# beside them: a tester carries its sample, and several testers share one -- a project which builds
# two executables has two testers -- so they are deduplicated by the manifest key each sample
# carries.
#
# Samples are filtered on `meta.available` rather than built wholesale: a few are marked broken with
# a measured `meta.problems` entry (an upstream API change with no version here that compiles, for
# instance), and forcing those would make this aggregate impossible to keep green.
#
# The components are named rather than discovered by filtering `cudaPackages`; see the note in
# `sampleComponentNames.nix`, which is where they are named.
#
# No GPU is needed; this is compilation only. Running the programs is what each tester's
# `passthru.gpuCheck` does, and those require the `cuda` system feature.
{
  cudaMajorMinorVersion,
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
  };

  # Filtered on carrying a sample rather than on anything about the name: `recurseIntoAttrs` leaves a
  # boolean beside the testers, and the manifest and program checks are derivations which run no
  # sample. Neither yields one.
  #
  # `sampleKey` and `component` are put on the sample by `mkSamples`, which asserts that
  # `buildSample` forwarded them rather than leaving this file to discover a missing attribute with
  # no indication of who should have set it.
  samplesOf =
    componentTests:
    lib.listToAttrs (
      map (tester: lib.nameValuePair tester.sample.sampleKey tester.sample) (
        lib.filter (tester: tester ? sample) (lib.filter lib.isDerivation (lib.attrValues componentTests))
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

  # Every attribute of the tests scope whose name says it is a component's samples.
  #
  # `sampleComponentNames` gives a reason for not discovering the list by filtering -- that filtering
  # forces every attribute of the package set, deprecated aliases included -- and that reason is
  # about `cudaPackages`. It does not apply here: these names are already in hand, and reading them
  # forces nothing.
  #
  # `cuda-library-samples` shares the suffix without being one of these. It is the source repository
  # the samples are built from, an attribute in its own right so that a component can select a
  # revision by date, and it has no testers to collect.
  discoveredComponentNames = lib.filter (
    name: lib.hasSuffix "-samples" name && name != "cuda-library-samples"
  ) (lib.attrNames tests);

  # Adding a component's samples without listing them in `sampleComponentNames` drops them from this
  # aggregate silently: it collects what it is told about, compiles everything else, and goes green.
  # The opposite direction already fails, on a missing attribute, so without this the drift is
  # one-directional -- and it is the direction someone takes when adding a component.
  undeclaredComponentNames = lib.subtractLists sampleComponentNames discoveredComponentNames;

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
    ''
    + lib.optionalString (undeclaredComponentNames != [ ]) ''
      nixErrorLog "the tests scope carries ${lib.concatStringsSep ", " undeclaredComponentNames}, which sampleComponentNames does not list"
      nixErrorLog "this aggregate compiles what it is told about, so those components' samples are built by nothing here"
      nixErrorLog "add them to sampleComponentNames, which is where the components with samples are named"
      exit 1
    '';
in
(linkFarm "${cudaNamePrefix}-samples-built" perComponent).overrideAttrs (prevAttrs: {
  # `linkFarm` names its result and nothing else, so `lib.getName` would parse that name back apart;
  # see the note beside `mkTester`'s `pname`. There is no one component to take a version from --
  # this aggregates all of them -- so it is the package set's, which is what the name prefix already
  # says this derivation is one of.
  pname = "${cudaNamePrefix}-samples-built";
  version = cudaMajorMinorVersion;

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
