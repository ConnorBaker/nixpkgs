# One runner per project; executable-specific settings are data, not separate derivations.
{
  config,
  coreutils,
  cudaNamePrefix,
  lib,
  mkTest,
  python3,
  writeShellApplication,
  writeText,
}:
let
  inherit (import ../../../../../stdenv/generic/problems.nix { inherit lib; })
    genHandlerSwitch
    processProblems
    problemsType
    ;
  inherit (genHandlerSwitch config) handlerForProblem;
in
{
  sample,
  invocations ? sample.invocations,
}:
let
  testerName = "${cudaNamePrefix}-${sample.pname}-tester";
  configured = lib.mapAttrs (
    program:
    # The closed pattern rejects unknown fields; @ keeps the supplied record sparse.
    # Execution defaults belong to runProject.py, not to a second normalization here.
    invocation@{
      args ? null,
      dataFiles ? null,
      expectedOutputs ? null,
      workSubdir ? null,
      runtimeEnv ? null,
      problems ? { },
    }:
    let
      # Only this executable's problems belong here. Package prerequisites are enforced
      # by the sample/runner derivations, not reinterpreted under each program's name.
      pname = "${sample.pname}-${program}";
      policy = processProblems pname (
        lib.mapAttrsToList (name: problem: {
          inherit name problem;
          kind = problem.kind or name;
          handler = handlerForProblem (problem.kind or name) name pname;
        }) problems
      );
    in
    assert lib.assertMsg (problemsType.verify problems) "${pname}: invalid invocation problems";
    lib.foldl' (value: warning: lib.warn "${pname}: ${warning.msg}" value) (
      removeAttrs invocation [ "problems" ]
      // {
        available = policy.error == null;
        reason = if policy.error == null then "" else policy.error.msg;
      }
    ) policy.warnings
  ) invocations;
  settings = writeText "${testerName}.json" (
    builtins.toJSON {
      sample = "${lib.getBin sample}";
      invocations = configured;
      path = lib.makeBinPath [
        sample
        coreutils
      ];
    }
  );
in
(writeShellApplication {
  name = testerName;
  inheritPath = false;
  runtimeInputs = [ python3 ];
  text = ''
    exec python3 ${./runProject.py} ${settings} "$@"
  '';
  derivationArgs = {
    pname = testerName;
    inherit (sample) version;
    postCheck = ''
      ${python3.interpreter} ${./runProject.py} ${settings} --validate
    '';
  };
  passthru = {
    inherit sample;
    minCudaCapability = sample.minCudaCapability or null;
    invocations = configured;
  };
  meta = {
    description = "Run every available executable from ${sample.pname}";
    mainProgram = testerName;
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    teams = [ lib.teams.cuda ];
    broken = !sample.meta.available;
  };
}).overrideAttrs
  (
    finalAttrs: prevAttrs: {
      passthru = prevAttrs.passthru // {
        tests.run = mkTest { tester = finalAttrs.finalPackage; };
      };
    }
  )
