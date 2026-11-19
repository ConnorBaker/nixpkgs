# shellcheck shell=bash

# Only run the hook from nativeBuildInputs when strictDeps is set
if [[ -n ${removeStubsFromRunpathHookOnce-} ]]; then
  # shellcheck disable=SC2154
  nixDebugLog "skipping sourcing removeStubsFromRunpathHook.bash (hostOffset=$hostOffset) (targetOffset=$targetOffset)" \
    "because it has already been sourced"
  return 0
fi

declare -g removeStubsFromRunpathHookOnce=1

nixLog "sourcing removeStubsFromRunpathHook.bash (hostOffset=$hostOffset) (targetOffset=$targetOffset)"

# NOTE: Adding to prePhases to ensure all setup hooks are sourced prior to adding our hook.
appendToVar prePhases removeStubsFromRunpathHookRegistration
nixLog "added removeStubsFromRunpathHookRegistration to prePhases"

# Registering during prePhases ensures that all setup hooks are sourced prior to installing ours,
# allowing us to always go after autoAddDriverRunpath and autoPatchelfHook.
removeStubsFromRunpathHookRegistration() {
  local postFixupHook

  for postFixupHook in "${postFixupHooks[@]}"; do
    if [[ $postFixupHook == "autoFixElfFiles addDriverRunpath" ]]; then
      nixLog "discovered 'autoFixElfFiles addDriverRunpath' in postFixupHooks; this hook should be unnecessary when" \
        "linking against stub files!"
    fi
  done

  postFixupHooks+=("autoFixElfFiles removeStubsFromRunpath")
  nixLog "added removeStubsFromRunpath to postFixupHooks"

  return 0
}

removeStubsFromRunpath() {
  local libPath
  local runpathEntry
  local -a origRunpathEntries=()
  local -a newRunpathEntries=()
  local -r driverLinkLib="@driverLinkLib@"
  local sawStub=0 addedDriver=0

  if [[ $# -eq 0 ]]; then
    nixErrorLog "no library path provided" >&2
    exit 1
  elif [[ $# -gt 1 ]]; then
    nixErrorLog "too many arguments" >&2
    exit 1
  elif [[ $1 == "" ]]; then
    nixErrorLog "empty library path" >&2
    exit 1
  else
    libPath="$1"
  fi

  getRunpathEntries "$libPath" origRunpathEntries

  for runpathEntry in "${origRunpathEntries[@]}"; do
    case $runpathEntry in
    # Keep the earliest driver or stub position and all other entries in order.
    *-cuda*/stubs|*-cuda*-stubs/lib*)
      sawStub=1
      runpathEntry=$driverLinkLib
      ;;
    esac
    if [[ $runpathEntry == "$driverLinkLib" ]]; then
      ((addedDriver)) && continue
      addedDriver=1
    fi
    newRunpathEntries+=("$runpathEntry")
  done
  ((sawStub)) || return 0

  local -r newRunpath=$(concatStringsSep ":" newRunpathEntries)
  patchelf --set-rpath "$newRunpath" "$libPath"
}
