# Prints the command line recorded in each note written by nvlink.
nvlinkOptions() {
  cuobjdump -elf "$1" \
    | awk '/Tool Name:/ { nvlink = ($3 == "nvlink") } nvlink && /Arguments:/ { sub(/.*Arguments: /, ""); print; nvlink = 0 }'
}

# Fails if a note in the file refers to the Nix store (by the hash of a store path, as Nix finds references), or if
# nvlink wrote no note where it should have.
checkNotes() {
  if cuobjdump -elf "$1" | grep -E 'Tool [A-Za-z ]+: .*[0-9a-df-np-sv-z]{32}'; then
    nixErrorLog "a note in $1 refers to the Nix store"
    exit 1
  fi
  local options
  options="$(nvlinkOptions "$1")"
  if [[ -z $options ]] && "$recordsCommandLine"; then
    nixErrorLog "found no note from nvlink in $1"
    exit 1
  fi
  nixLog "nvlink recorded in $1: $options"
}

# Runs a command which must fail with the wrapper's error, message, and remove the output, result.
expectFailure() {
  local message="$1"
  shift
  if "$@" 2> stderr.txt; then
    nixErrorLog "expected $* to fail"
    exit 1
  fi
  cat stderr.txt
  grep -F "nvlink wrapper: error: $message" stderr.txt
  if [[ -e result ]]; then
    nixErrorLog "expected the output to be removed"
    exit 1
  fi
}

# The wrapper removes any directory it used for nvcc's intermediate files.
checkScratchCleanup() {
  if [[ -n $(find "$TMPDIR" -maxdepth 1 -name 'nvcc-keep-*') ]]; then
    nixErrorLog "the wrapper left a directory in $TMPDIR"
    exit 1
  fi
}
