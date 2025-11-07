# shellcheck shell=bash

if [[ -n ${strictDeps:-} && ${hostOffset:-0} -ne -1 ]]; then
  nixLog "skipping sourcing buildRedistHook.bash (hostOffset=${hostOffset:-0}) (targetOffset=${targetOffset:-0})"
  return 0
fi
nixLog "sourcing buildRedistHook.bash (hostOffset=${hostOffset:-0}) (targetOffset=${targetOffset:-0})"

buildRedistHookRegistration() {
  postUnpackHooks+=(unpackCudaLibSubdir)
  nixLog "added unpackCudaLibSubdir to postUnpackHooks"

  postUnpackHooks+=(unpackCudaPkgConfigDirs)
  nixLog "added unpackCudaPkgConfigDirs to postUnpackHooks"

  prePatchHooks+=(patchCudaPkgConfig)
  nixLog "added patchCudaPkgConfig to prePatchHooks"

  if [[ -z ${allowFHSReferences-} ]]; then
    postInstallCheckHooks+=(checkCudaFhsRefs)
    nixLog "added checkCudaFhsRefs to postInstallCheckHooks"
  fi

  postInstallCheckHooks+=(checkCudaNonEmptyOutputs)
  nixLog "added checkCudaNonEmptyOutputs to postInstallCheckHooks"

  preFixupHooks+=(fixupPropagatedBuildOutputsForMultipleOutputs)
  nixLog "added fixupPropagatedBuildOutputsForMultipleOutputs to preFixupHooks"

  postFixupHooks+=(fixupCudaPropagatedBuildOutputsToOut)
  nixLog "added fixupCudaPropagatedBuildOutputsToOut to postFixupHooks"

  # NOTE: We need to do this in postFixup since we don't write the dependency on removeStubsFromRunpathHook until
  # postFixup -- recall recordPropagatedDependencies happens during fixupPhase.
  # NOTE: Iff is shorthand for "if and only if" -- the logical biconditional.
  postFixupHooks+=(checkCudaHasStubsIffIncludeRemoveStubsFromRunpathHook)
  nixLog "added checkCudaHasStubsIffIncludeRemoveStubsFromRunpathHook to postFixupHooks"
}

buildRedistHookRegistration

unpackCudaLibSubdir() {
  local -r cudaLibDir="${NIX_BUILD_TOP:?}/${sourceRoot:?}/lib"
  local -r versionedCudaLibDir="$cudaLibDir/${cudaMajorVersion:?}"

  if [[ ! -d $versionedCudaLibDir ]]; then
    return 0
  fi

  nixLog "found versioned CUDA lib dir: $versionedCudaLibDir"

  mv \
    --verbose \
    --no-clobber \
    "$versionedCudaLibDir" \
    "${cudaLibDir}-new"
  rm --verbose --recursive "$cudaLibDir" || {
    nixErrorLog "could not delete $cudaLibDir: $(ls -laR "$cudaLibDir")"
    exit 1
  }
  mv \
    --verbose \
    --no-clobber \
    "${cudaLibDir}-new" \
    "$cudaLibDir"

  return 0
}

# Pkg-config's setup hook expects configuration files in $out/share/pkgconfig
unpackCudaPkgConfigDirs() {
  local path
  local -r pkgConfigDir="${NIX_BUILD_TOP:?}/${sourceRoot:?}/share/pkgconfig"

  for path in "${NIX_BUILD_TOP:?}/${sourceRoot:?}"/{pkg-config,pkgconfig}; do
    [[ -d $path ]] || continue
    mkdir -p "$pkgConfigDir"
    mv \
      --verbose \
      --no-clobber \
      --target-directory "$pkgConfigDir" \
      "$path"/*
    rm --recursive --dir "$path" || {
      nixErrorLog "$path contains non-empty directories: $(ls -laR "$path")"
      exit 1
    }
  done

  return 0
}

patchCudaPkgConfig() {
  local pc

  for pc in "${NIX_BUILD_TOP:?}/${sourceRoot:?}"/share/pkgconfig/*.pc; do
    nixLog "patching $pc"
    sed -i \
      -e "s|^cudaroot\s*=.*\$|cudaroot=${!outputDev:?}|" \
      -e "s|^libdir\s*=.*/lib\$|libdir=${!outputLib:?}/lib|" \
      -e "s|^includedir\s*=.*/include\$|includedir=${!outputInclude:?}/include|" \
      "$pc"
  done

  for pc in "${NIX_BUILD_TOP:?}/${sourceRoot:?}"/share/pkgconfig/*-"${cudaMajorMinorVersion:?}.pc"; do
    nixLog "creating unversioned symlink for $pc"
    ln -s "$(basename "$pc")" "${pc%-"${cudaMajorMinorVersion:?}".pc}".pc
  done

  return 0
}

checkCudaFhsRefs() {
  nixLog "checking for FHS references..."
  local -a outputPaths=()
  local firstMatches

  mapfile -t outputPaths < <(for outputName in $(getAllOutputNames); do echo "${!outputName:?}"; done)
  firstMatches="$(grep --max-count=5 --recursive --exclude=LICENSE /usr/ "${outputPaths[@]}")" || true
  if [[ -n $firstMatches ]]; then
    nixErrorLog "detected references to /usr: $firstMatches"
    exit 1
  fi

  return 0
}

checkCudaNonEmptyOutputs() {
  local outputName
  local dirs
  local -a failingOutputNames=()

  for outputName in $(getAllOutputNames); do
    [[ ${outputName:?} == "out" || ${outputName:?} == "${outputDev:?}" ]] && continue
    dirs="$(find "${!outputName:?}" -mindepth 1 -maxdepth 1)" || true
    if [[ -z $dirs || $dirs == "${!outputName:?}/nix-support" ]]; then
      failingOutputNames+=("${outputName:?}")
    fi
  done

  if ((${#failingOutputNames[@]})); then
    nixErrorLog "detected empty (excluding nix-support) outputs: ${failingOutputNames[*]}"
    nixErrorLog "this typically indicates a failure in packaging or moveToOutput ordering"
    exit 1
  fi

  return 0
}

# Any redistributable providing stubs should set includeRemoveStubsFromRunpathHook to true -- since we don't track the
# contents of the redistributables, it's only included by default if there is a stubs output.
# This check additionally requires that any output which has a stubs directory includes a dependency on
# includeRemoveStubsFromRunpathHook -- that way, if *any* of them are used, the hook is brought in as well.
# Since includeRemoveStubsFromRunpathHook only adds the hook to whatever outputStubs resolves to, having stubs present
# across multiple outputs will result in an error.
checkCudaHasStubsIffIncludeRemoveStubsFromRunpathHook() {
  local outputName
  local -i hasStubs
  local -i hasRemoveStubsFromRunpathHook
  local -a outputNamesWronglyExcludingHook=()
  local -a outputNamesWronglyIncludingHook=()

  for outputName in $(getAllOutputNames); do
    # Record the output if it contains a directory named "stubs" and doesn't include a dependency on
    # removeStubsFromRunpathHook.
    hasStubs=0
    if find "${!outputName:?}" -mindepth 1 -type d -name stubs -print -quit | grep --silent .; then
      hasStubs=1
    fi

    hasRemoveStubsFromRunpathHook=0
    if
      grep --silent --no-messages removeStubsFromRunpathHook "${!outputName:?}/nix-support/propagated-build-inputs"
    then
      hasRemoveStubsFromRunpathHook=1
    fi

    if ((hasStubs && !hasRemoveStubsFromRunpathHook)); then
      # Outputs with stubs must include the hook.
      outputNamesWronglyExcludingHook+=("${outputName:?}")
    elif ((!hasStubs && hasRemoveStubsFromRunpathHook)); then
      # Outputs without stubs cannot include the hook.
      outputNamesWronglyIncludingHook+=("${outputName:?}")
    fi
  done

  if ((${#outputNamesWronglyExcludingHook[@]})); then
    nixErrorLog "includeRemoveStubsFromRunpathHook is false but we detected outputs containing a stubs" \
      "directory: ${outputNamesWronglyExcludingHook[*]}"
    nixErrorLog "ensure redistributables providing stubs set includeRemoveStubsFromRunpathHook to true"
  fi

  if ((${#outputNamesWronglyIncludingHook[@]})); then
    nixErrorLog "includeRemoveStubsFromRunpathHook is true but we detected outputs without a stubs" \
      "directory: ${outputNamesWronglyIncludingHook[*]}"
    nixErrorLog "ensure redistributables without stubs do not set includeRemoveStubsFromRunpathHook to true"
  fi

  if ((${#outputNamesWronglyExcludingHook[@]} || ${#outputNamesWronglyIncludingHook[@]})); then
    exit 1
  fi

  return 0
}

# TODO(@connorbaker): https://github.com/NixOS/nixpkgs/issues/323126.
# _multioutPropagateDev() currently expects a space-separated string rather than an array.
# NOTE: Because _multioutPropagateDev is a postFixup hook, we correct it in preFixup.
fixupPropagatedBuildOutputsForMultipleOutputs() {
  nixLog "converting propagatedBuildOutputs to a space-separated string"
  # shellcheck disable=SC2124
  export propagatedBuildOutputs="${propagatedBuildOutputs[@]}"
  return 0
}

# The multiple outputs setup hook only propagates build outputs to dev.
# We want to propagate them to out as well, in case the user interpolates
# the package into a string -- in such a case, the dev output is not selected
# and no propagation occurs.
# NOTE: This must run in postFixup because fixupPhase nukes the propagated dependency files.
fixupCudaPropagatedBuildOutputsToOut() {
  local output

  # The `out` output should largely be empty save for nix-support/propagated-build-inputs.
  # In effect, this allows us to make `out` depend on all the other components.
  # NOTE: It may have been deleted if it was empty, which is why we must recreate it.
  mkdir -p "${out:?}/nix-support"

  # NOTE: We must use printWords to ensure the output is a single line.
  for output in $propagatedBuildOutputs; do
    # Propagate the other components to the out output
    nixLog "adding ${!output:?} to propagatedBuildInputs of ${out:?}"
    printWords "${!output:?}" >>"${out:?}/nix-support/propagated-build-inputs"
  done

  return 0
}
