# shellcheck shell=bash

# getRunpathEntries
# Append the runpath entries of path to the output array.
# NOTE: This function does not check if path is a valid ELF file.
#
# Arguments:
# - path: the path to the ELF file
# - outputArrRef: a reference to an array (mutated only by appending)
#
# Returns 1 if the file is not dynamically linked (i.e. patchelf fails to print the rpath).
# Returns 0 if the file is dynamically linked and the runpath is appended to the output array.
getRunpathEntries() {
  if (($# != 2)); then
    nixErrorLog "expected two arguments!"
    nixErrorLog "usage: getRunpathEntries path outputArrRef"
    exit 1
  fi

  local -r path="$1"
  # shellcheck disable=SC2178
  local -rn outputArrRef="$2"

  if [[ ! -f $path ]]; then
    nixErrorLog "path $path is not a file"
    exit 1
  elif ! isDeclaredArray "${!outputArrRef}"; then
    nixErrorLog "second arugment outputArrRef must be an array reference"
    exit 1
  fi

  # Declare runpath separately to avoid masking the return value of patchelf.
  local runpath
  # Files that are not dynamically linked cause patchelf to exit with a non-zero status and print to stderr.
  # If patchelf fails to print the rpath, we assume the file is not dynamically linked.
  runpath="$(patchelf --print-rpath "$path" 2>/dev/null)" || return 1

  # If the runpath is empty and we feed it to mapfile, it gives us a singleton array with an empty string.
  # We want to avoid that, so we check if the runpath is empty before trying to populate runpathEntries.
  local -a runpathEntries=()
  if [[ -n $runpath ]]; then
    mapfile -d ':' -t runpathEntries < <(echo -n "$runpath")
  fi

  outputArrRef+=("${runpathEntries[@]}")

  return 0
}
