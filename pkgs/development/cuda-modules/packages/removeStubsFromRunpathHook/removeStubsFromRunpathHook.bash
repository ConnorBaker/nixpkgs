# shellcheck shell=bash

if [[ -n ${removeStubsFromRunpathHookOnce-} ]]; then
  nixDebugLog "skipping sourcing removeStubsFromRunpathHook.bash (hostOffset=${hostOffset:-UNSET}) (targetOffset=${targetOffset:-UNSET})" \
    " because it has already been sourced"
  return 0
fi

declare -g removeStubsFromRunpathHookOnce=1

nixLog "sourcing removeStubsFromRunpathHook.bash (hostOffset=${hostOffset:-UNSET}) (targetOffset=${targetOffset:-UNSET})"

# NOTE: Adding to prePhases to ensure all setup hooks are sourced prior to adding our hook.
appendToVar prePhases removeStubsFromRunpathHookRegistration
nixLog "added removeStubsFromRunpathHookRegistration to prePhases"

# Registering during prePhases ensures that all setup hooks are sourced prior to installing ours,
# allowing us to always go after autoAddDriverRunpath and autoPatchelfHook.
removeStubsFromRunpathHookRegistration() {
  local postFixupHook

  # Check if "autoFixElfFiles addDriverRunpath" is in postFixupHooks.
  # If it is, warn the user about it -- it does not play well with other hooks modifying the runpath and should be
  # unnecessary when linking against stub files (which is the only reason this setup hook would be sourced), since
  # the stub runpath entries are replaced with the driver link.
  for postFixupHook in "${postFixupHooks[@]}"; do
    if [[ $postFixupHook == "autoFixElfFiles addDriverRunpath" ]]; then
      nixLog "discovered 'autoFixElfFiles addDriverRunpath' in postFixupHooks; this hook should be unnecessary when" \
        " linking against stub files!"
    fi
  done

  # NOTE: We assume postFixupHooks is an array to abuse calling convention, allowing us to call the higher-order
  # bash function autoFixElfFiles.
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
  local -i driverLinkLibSightings=0

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

  # TODO(@connorbaker): Order of runpath entries matters.
  for runpathEntry in "${origRunpathEntries[@]}"; do
    case $runpathEntry in
    # NOTE: This assumes stubs have "-cuda" (`cudaNamePrefix` in `buildRedist`) in name.
    *-cuda*/lib/stubs)
    *-cuda*-stubs/lib)
      if ((driverLinkLibSightings)); then
        nixDebugLog "removeStubsFromRunpath $libPath: dropping redundant runpath entry $runpathEntry"
      else
        # First occurrence of driverLinkLib.
        nixDebugLog "removeStubsFromRunpath $libPath: replacing runpath entry, $runpathEntry -> $driverLinkLib"
        newRunpathEntries+=("$driverLinkLib")
        ((++driverLinkLibSightings )) || true # NOTE: (( 0 )) sets exit code 1
      fi
      ;;
    *)
      nixDebugLog "removeStubsFromRunpath $libPath: keeping runpath entry $runpathEntry"
      newRunpathEntries+=("$runpathEntry")
      [[ $runpathEntry == "$driverLinkLib" ]] && ((++driverLinkLibSightings)) || true
      ;;
    esac
  done

  # NOTE(@connorbaker): Files that are not dynamically linked cause patchelf to
  # exit with a non-zero status and print to stderr. If patchelf fails to print
  # the rpath, we assume the file is not dynamically linked.
  local -r newRunpath=$(concatStringsSep ":" newRunpathEntries)
  patchelf --set-rpath "$newRunpath" "$libPath" 2>/dev/null || return 1
}
