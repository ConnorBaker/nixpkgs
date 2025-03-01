{
  callPackages,
  isDeclaredArray,
  lib,
  makeSetupHook,
}:
# TODO: Would it be a mistake to provided an occursInSortedArray?
makeSetupHook {
  name = "sortArray";
  propagatedBuildInputs = [ isDeclaredArray ];
  passthru.tests = callPackages ./tests.nix { };
  meta = {
    description = "Sorts an array";
    maintainers = [ lib.maintainers.connorbaker ];
  };
} ./sortArray.bash
