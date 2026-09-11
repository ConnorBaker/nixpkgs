# Execution is a separate derivation: ordinary sample builds need no GPU.
{
  _cuda,
  lib,
  runCommand,
}:
{ tester }:
runCommand "${tester.pname}-gpu-check"
  {
    pname = "${tester.pname}-gpu-check";
    inherit (tester) version;
    nativeBuildInputs = [ tester ];
    requiredSystemFeatures = [
      "cuda"
    ]
    ++ lib.optionals (tester.minCudaCapability or null != null) [
      (_cuda.lib.mkCudaSystemFeature tester.minCudaCapability)
    ];
    passthru = { inherit tester; };
    meta = {
      description = "${tester.meta.description}, in a GPU sandbox";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
      teams = [ lib.teams.cuda ];
      broken = !tester.meta.available;
    };
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    "${lib.getExe tester}" 2>&1 | tee "$out/test.log"
  ''
