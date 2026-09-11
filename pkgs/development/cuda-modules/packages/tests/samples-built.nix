# Collect only build-outcome checks, preserving the source tree's attribute paths.
{
  cudaMajorMinorVersion,
  cudaNamePrefix,
  lib,
  linkFarm,
  tests,
}:
let
  buildChecks =
    path: sample:
    lib.optionals (lib.isDerivation sample) (
      lib.mapAttrsToList
        (role: check: {
          name = lib.concatStringsSep "/" (lib.tail path ++ [ role ]);
          path = check;
        })
        # Arbitrary passthru.tests can require a GPU, including through dependencies.
        (
          lib.filterAttrs (_: check: check.meta.available or false) (
            lib.intersectAttrs {
              build = null;
              buildFailure = null;
            } sample.tests
          )
        )
    );
  subtrees = lib.mapAttrs (
    name: tree:
    linkFarm "${cudaNamePrefix}-${name}" (
      lib.concatLists (
        lib.mapAttrsToListRecursiveCond (_: node: !lib.isDerivation node) buildChecks {
          ${name} = tree;
        }
      )
    )
  ) (lib.filterAttrs (_: node: lib.isAttrs node && !lib.isFunction node) tests.cuda-library-samples);
in
(linkFarm "${cudaNamePrefix}-samples-built" subtrees).overrideAttrs {
  pname = "${cudaNamePrefix}-samples-built";
  version = cudaMajorMinorVersion;
  passthru.subtrees = lib.recurseIntoAttrs subtrees;
  meta = {
    description = "Build CUDA library samples, validate invocations and check expected failures";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    teams = [ lib.teams.cuda ];
  };
}
