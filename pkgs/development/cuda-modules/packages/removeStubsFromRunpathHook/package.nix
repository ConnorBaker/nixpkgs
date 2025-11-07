{
  addDriverRunpath,
  arrayUtilities,
  autoFixElfFiles,
  makeSetupHook,
}:
makeSetupHook {
  name = "removeStubsFromRunpathHook";
  propagatedBuildInputs = [
    # NOTE: All depend on patchelf, provided by stdenv
    arrayUtilities.getRunpathEntries
    autoFixElfFiles
  ];

  substitutions = {
    driverLinkLib = addDriverRunpath.driverLink + "/lib";
  };
} ./removeStubsFromRunpathHook.bash
