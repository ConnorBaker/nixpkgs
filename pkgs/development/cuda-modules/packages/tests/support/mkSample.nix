# Attach checks without changing the package being checked. Neither invocations nor
# expected outcomes are build inputs; a known failure remains directly buildable to reproduce it.
{
  buildSample,
  lib,
  mkProjectTester,
  testers,
}:
lib.extendMkDerivation {
  constructDrv = buildSample;
  excludeDrvArgNames = [
    "invocations"
    "expectedFailure"
  ];
  extendDrvArgs =
    finalAttrs:
    {
      invocations ? { },
      expectedFailure ? null,
      passthru ? { },
      ...
    }:
    let
      sample = finalAttrs.finalPackage;
      checkFailure =
        {
          message,
          expectedBuilderExitCode,
          expectedBuilderLogEntries,
        }:
        assert lib.assertMsg
          (
            lib.isString message
            && message != ""
            && lib.isInt expectedBuilderExitCode
            && expectedBuilderExitCode > 0
            && expectedBuilderLogEntries != [ ]
            && lib.all (entry: lib.isString entry && entry != "") expectedBuilderLogEntries
          )
          "sample ${sample.sampleRoot}: an expected failure needs a message, nonzero exit code and diagnostics";
        (testers.testBuildFailure' {
          name = "${sample.name}-build-failure";
          drv = sample;
          inherit expectedBuilderExitCode expectedBuilderLogEntries;
        }).overrideAttrs
          (
            finalCheck: prevCheck: {
              pname = "${sample.pname}-build-failure";
              inherit (sample) version;
              meta = prevCheck.meta // {
                description = message;
                broken = !finalCheck.failed.meta.available;
              };
            }
          );
    in
    {
      passthru = passthru // {
        inherit expectedFailure;
        invocations = lib.toFunction invocations { inherit (finalAttrs) src sampleRoot; };
        testers = {
          all = mkProjectTester { inherit sample; };
        }
        // (passthru.testers or { });
        tests =
          (
            if expectedFailure == null then
              {
                build = sample.testers.all;
                run = sample.testers.all.tests.run;
              }
            else
              { buildFailure = checkFailure expectedFailure; }
          )
          // (passthru.tests or { });
      };
    };
}
