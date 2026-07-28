# Checks `_cuda.lib.getCudaSystemFeatures` and `_cuda.lib.mkCudaSystemFeature`, which decide which
# builder a GPU test is scheduled onto.
#
# Nothing else can catch a defect in them. A wrong feature name or a closure which drops a capability
# does not fail a build: it leaves the affected tests unschedulable, which Hydra reports as a queue
# that never drains and a developer reads as "I have no machine with that GPU".
#
# Written as properties rather than as expected lists, because the list a capability closes over grows
# whenever a capability is added to `_cuda.db`, and a test which has to be re-typed on every such
# addition is one which gets re-typed rather than read.
{
  _cuda,
  cudaNamePrefix,
  lib,
  runCommand,
}:
let
  inherit (_cuda.db) allSortedCudaCapabilities cudaCapabilityToInfo;
  inherit (_cuda.lib) getCudaSystemFeatures mkCudaSystemFeature;

  isFeatureSet =
    cudaCapability:
    cudaCapabilityToInfo.${cudaCapability}.isArchitectureSpecific
    || cudaCapabilityToInfo.${cudaCapability}.isFamilySpecific;

  gpuCapabilities = lib.filter (
    cudaCapability: !isFeatureSet cudaCapability
  ) allSortedCudaCapabilities;

  # The capabilities the cases below name, checked separately so that a case does not quietly stop
  # testing anything if one of them is ever retired from the db.
  namedCapabilities = [
    "8.0"
    "8.9"
    "9.0"
    "9.0a"
    "10.0"
    "10.0a"
    "10.0f"
    "10.1"
    "10.3"
    "10.3f"
    "11.0"
    "12.0"
    "12.1"
    "12.1a"
  ];

  # `tryEval` rather than a bare call: the two rejection cases pass only if evaluation fails.
  evalFails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  cases = [
    {
      name = "a feature is the capability with its dots dropped";
      ok = mkCudaSystemFeature "8.9" == "cuda-sm-89" && mkCudaSystemFeature "10.0f" == "cuda-sm-100f";
    }
    {
      name = "every GPU advertises the feature a test of its own capability requires";
      ok = lib.all (
        cudaCapability:
        lib.elem (mkCudaSystemFeature cudaCapability) (getCudaSystemFeatures [ cudaCapability ])
      ) gpuCapabilities;
    }
    {
      name = "every advertised feature names a known capability";
      ok =
        let
          knownFeatures = lib.map mkCudaSystemFeature allSortedCudaCapabilities;
        in
        lib.all (feature: lib.elem feature knownFeatures) (getCudaSystemFeatures gpuCapabilities);
    }
    {
      name = "a GPU below the minimum is not offered the test";
      ok = !lib.elem (mkCudaSystemFeature "8.9") (getCudaSystemFeatures [ "8.0" ]);
    }
    {
      name = "a GPU at or above the minimum is offered the test";
      ok =
        lib.all
          (cudaCapability: lib.elem (mkCudaSystemFeature "8.9") (getCudaSystemFeatures [ cudaCapability ]))
          [
            "8.9"
            "9.0"
            "10.0"
          ];
    }
    {
      name = "an architecture-specific feature set is offered only to its own GPU";
      ok =
        lib.elem (mkCudaSystemFeature "9.0a") (getCudaSystemFeatures [ "9.0" ])
        && !lib.elem (mkCudaSystemFeature "9.0a") (getCudaSystemFeatures [ "10.0" ]);
    }
    {
      # The case a closure taken by version alone gets wrong in the other direction: "12.1a" sorts
      # above "12.1", so ordering by version would withhold from an SM 12.1 GPU the one feature set
      # which is specifically its own.
      name = "a GPU is offered its own architecture-specific feature set";
      ok = lib.elem (mkCudaSystemFeature "12.1a") (getCudaSystemFeatures [ "12.1" ]);
    }
    {
      # A family is a major compute capability version, so 10.0f reaches every 10.x at or above 10.0
      # and stops at the family boundary. This is the property which is wrong if `f` is treated like
      # `a`: SM 10.3 would be refused work it can do.
      name = "a family-specific feature set reaches later minors of its own family";
      ok =
        lib.all
          (cudaCapability: lib.elem (mkCudaSystemFeature "10.0f") (getCudaSystemFeatures [ cudaCapability ]))
          [
            "10.0"
            "10.1"
            "10.3"
          ];
    }
    {
      name = "a family-specific feature set stops at the family boundary";
      ok =
        lib.all
          (cudaCapability: !lib.elem (mkCudaSystemFeature "10.0f") (getCudaSystemFeatures [ cudaCapability ]))
          [
            "9.0"
            "11.0"
            "12.0"
            "12.1"
          ];
    }
    {
      name = "a family-specific feature set does not reach earlier minors of its own family";
      ok = !lib.elem (mkCudaSystemFeature "10.3f") (getCudaSystemFeatures [ "10.0" ]);
    }
    {
      # The distinction between the two suffixes, stated as the difference it makes: 10.3 runs the
      # family-specific code built for 10.0 and does not run the architecture-specific code.
      name = "an architecture-specific feature set does not reach where its family-specific sibling does";
      ok =
        lib.elem (mkCudaSystemFeature "10.0f") (getCudaSystemFeatures [ "10.3" ])
        && !lib.elem (mkCudaSystemFeature "10.0a") (getCudaSystemFeatures [ "10.3" ]);
    }
    {
      name = "several GPUs advertise the union of their closures";
      ok =
        let
          both = getCudaSystemFeatures [
            "9.0"
            "10.0"
          ];
        in
        lib.elem (mkCudaSystemFeature "9.0a") both
        && lib.elem (mkCudaSystemFeature "10.0a") both
        && lib.all (feature: lib.elem feature both) (getCudaSystemFeatures [ "10.0" ]);
    }
    {
      name = "the advertisement holds no duplicates";
      ok =
        let
          both = getCudaSystemFeatures [
            "9.0"
            "10.0"
          ];
        in
        lib.length both == lib.length (lib.unique both);
    }
    {
      name = "a feature set is rejected as a GPU rather than answered for its base capability";
      ok = evalFails (getCudaSystemFeatures [ "9.0a" ]);
    }
    {
      name = "an unknown capability is rejected";
      ok = evalFails (getCudaSystemFeatures [ "4.2" ]);
    }
  ];

  missing = lib.filter (
    cudaCapability: !(cudaCapabilityToInfo ? ${cudaCapability})
  ) namedCapabilities;
  failed = lib.filter (case: !case.ok) cases;
in
assert lib.asserts.assertMsg (
  missing == [ ]
) "these tests name capabilities which are no longer in _cuda.db: ${toString missing}";
assert lib.asserts.assertMsg (failed == [ ]) ''
  _cuda.lib.getCudaSystemFeatures failed:
  ${lib.concatMapStringsSep "\n" (case: "  - ${case.name}") failed}
'';
runCommand "${cudaNamePrefix}-tests-cuda-system-features"
  {
    __structuredAttrs = true;
    strictDeps = true;

    meta = {
      description = "Property checks for the CUDA capability system features";
      license = lib.licenses.mit;
      teams = [ lib.teams.cuda ];
    };
  }
  ''
    touch "$out"
  ''
