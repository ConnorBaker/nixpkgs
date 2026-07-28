# Wraps a tester executable in a derivation which runs it inside the sandbox.
#
# Running these requires a builder which advertises the `cuda` system feature and which exposes the
# driver and device nodes to the sandbox; see `programs.nix-required-mounts.presets.nvidia-gpu`.
#
# A sample which needs a minimum compute capability additionally requires a `cuda-sm-<capability>`
# feature. Building for a capability and running on it are different questions: the package set
# compiles for every configured capability, so a Blackwell-only sample builds happily on a machine
# which cannot execute it, and without this the test is scheduled there and dies with an opaque
# `cuBLAS API failed` abort rather than a legible scheduling refusal. What a builder has to advertise
# to be chosen -- the downward closure of its own capability, not the capability alone -- is
# `_cuda.lib.getCudaSystemFeatures`, which explains the closure, gives the line to configure a builder
# with, and states what the capability table does not know.
{
  _cuda,
  lib,
  runCommand,
}:
{
  # The executable to run, built by `mkTester`.
  tester,
}:
runCommand
  (
    if lib.hasInfix "-tester-" tester.name then
      lib.replaceString "-tester-" "-test-" tester.name
    else
      "${tester.name}-test"
  )
  {
    nativeBuildInputs = [ tester ];
    requiredSystemFeatures = [
      "cuda"
    ]
    # Named by the same function the builder's advertisement is named by, and not spelled out here:
    # the requirement and the advertisement have to agree exactly for anything to match, and a
    # disagreement between two independent spellings does not fail -- it leaves every gated test
    # unschedulable, which reads as "no builder available" rather than as a defect.
    ++ lib.optionals (tester.passthru.minCudaCapability or null != null) [
      (_cuda.lib.mkCudaSystemFeature tester.passthru.minCudaCapability)
    ];
    # The tester -- and through its own passthru the compiled sample -- so that a failing test can be
    # reproduced by hand, outside the sandbox and under nixGL, without looking up how it was built.
    # They hang off the test rather than sitting beside it under the component's `tests`, because
    # neither of them is a test.
    passthru = {
      inherit tester;
    };
    # Only the attributes we set deliberately: `tester.meta` has by this point been populated by
    # check-meta with derived attributes such as `name` and `position`, which describe the tester
    # rather than the test.
    meta = {
      description = "${tester.meta.description}, in the sandbox on a builder with a GPU";
      inherit (tester.meta) license platforms sourceProvenance;
      teams = tester.meta.teams or [ ];
      # A test of a tester which cannot be built here cannot be run here either, so the tester's
      # problems -- which are themselves the sample's -- are carried through. Without this the
      # explicit `meta` above would drop them and the test would claim to be available while its
      # only dependency is not.
      problems = tester.meta.problems or { };
    };
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    # stderr is folded into the log rather than left to the build output alone: the tester reports a
    # run which produced none of its `expectedOutputs` on stderr, so a log which captured only stdout
    # kept the sample's own chatter and dropped the one line saying what was wrong with it.
    #
    # `pipefail` is what makes the status the tester's rather than tee's; `$?` below is the
    # pipeline's, read before anything else in this block runs.
    "${lib.getExe tester}" 2>&1 | tee "$out/test.log" || {
      nixErrorLog "command failed with exit code $?"
      exit 1
    }
  ''
