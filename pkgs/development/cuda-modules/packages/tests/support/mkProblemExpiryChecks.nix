# Builds a sample which is recorded as unbuildable here, and requires it to still fail, for the
# reason recorded.
#
# A `meta.problems` entry is a claim about the world -- that a header does not declare a function,
# that a component is too old, that a sample calls an API which was renamed -- and every one of them
# is measured at the moment it is written and never again. Nothing notices when upstream repairs the
# sample or a component bump lands: the entry keeps the sample out of every build, so the thing which
# would have disagreed with it is exactly the thing it prevents from running. Left alone, a guard
# outlives its cause and silently subtracts a sample from the suite forever.
#
# So the guard is lifted, the sample is built, and the failure is required. `testers.testBuildFailure'`
# is what expresses that: it runs the build expecting it to fail, and fails if it succeeds.
#
# The failure has to be the recorded one, not merely a failure. A sample which stopped compiling for
# some unrelated reason -- a toolchain change, a patch which no longer applies -- would otherwise keep
# the guard alive while the reason written beside it had ceased to be true, which is the very drift
# this exists to catch. Each problem therefore states the diagnostic it was measured from, and the
# check requires that text in the log. The messages already quote those diagnostics; the evidence is
# the same fact in the form a build can be held to.
#
# This proves the problem still holds. It does not prove the message is a good description of it, and
# nothing can: `nvcompBatchedApiChanged` would go on passing if nvCOMP renamed the API a second time
# for a different reason, so long as the compiler still named the identifier the message quotes.
{
  lib,
  testers,
}:
{
  # The sample, as `buildSample` produced it: guards and all.
  sample,
  # problemEvidence :: AttrsOf { expectedBuilderExitCode :: Int; expectedBuilderLogEntries :: [String]; }
  # What the build must still do, per problem, in `testers.testBuildFailure'`'s own spelling. The
  # keys name entries in the sample's own `meta.problems`, which `buildSample` has already checked.
  problemEvidence,
}:
let
  # Every problem with evidence is lifted for every one of these builds, rather than each check
  # lifting only its own. A build stops at the first thing that stops it, so a sample which is
  # recorded as failing two ways cannot demonstrate the second while the first is still in force --
  # and lifting both makes each check ask the honest question: with nothing in the way, does this
  # build still fail in the manner this problem describes?
  #
  # Problems without evidence stay. They are of a different kind: a requirement the package set does
  # not meet, or a package this sample is built against being unavailable here. Lifting one of those
  # would not produce a build which fails for an interesting reason, it would produce one which
  # cannot be attempted at all.
  lifted = lib.attrNames problemEvidence;
  remaining = lib.removeAttrs sample.meta.problems lifted;

  unguarded = sample.overrideAttrs (prevAttrs: {
    meta = prevAttrs.meta // {
      problems = remaining;
    };
  });
in
lib.mapAttrs (
  problemName: evidence:
  (testers.testBuildFailure' {
    name = "${sample.name}-expiry-${problemName}";
    drv = unguarded;
    inherit (evidence) expectedBuilderExitCode expectedBuilderLogEntries;
  }).overrideAttrs
    (prevAttrs: {
      # `testBuildFailure'` names its result and nothing else; see the note beside `mkTester`'s
      # `pname`. Built from the sample's own `pname` rather than its `name`, which already carries
      # the version.
      pname = "${sample.pname}-expiry-${problemName}";
      inherit (sample) version;
      meta = prevAttrs.meta // {
        description = "Check that ${problemName} still stops ${sample.sampleRoot} from building";
        # Taken from the sample, which took them from the component: this compiles the sample's
        # sources against the component, so it is exactly as redistributable and exactly as portable
        # as the sample it fails to build.
        inherit (sample.meta) license platforms;
        teams = sample.meta.teams or [ ];
        # Whatever is left after the evidenced problems are lifted. A sample kept out by a
        # requirement this package set does not meet, or by an input which is unavailable here,
        # cannot be built in order to fail in an interesting way -- so this says so in the same terms
        # the sample does, and the aggregate which collects these filters on it rather than taking
        # the throw.
        problems = remaining;
      };
    })
) problemEvidence
