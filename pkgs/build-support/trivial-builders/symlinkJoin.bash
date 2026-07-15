# shellcheck shell=bash

# Build-side implementation of `symlinkJoin`, sourced after stdenv initialization.
# __structuredAttrs provides `strategies`, `pathStrategies`, and `failOnMissing`.

# __symlinkJoinRefuse rel message...
# Records errors and prevents duplicate reports below a failed path.
__symlinkJoinRefuse() {
  badPrefixes["$1"]="$1"
  errors+=("${@:2}")
}

# __symlinkJoinLookupByPrefix relPath tableRef resultRef
# Finds the most specific matching path or ancestor in tableRef and writes its value to resultRef.
# Returns 1 when no prefix matches; incorrect usage terminates the build.
__symlinkJoinLookupByPrefix() {
  (($# == 3)) || {
    nixErrorLog "internal error: __symlinkJoinLookupByPrefix requires path, table, and output variable"
    exit 1
  }

  local cand="$1"
  local -nr table="$2"
  local -n resultRef="$3"
  while :; do
    if [[ -n ${table[$cand]+x} ]]; then
      # shellcheck disable=SC2034
      # The nameref assignment writes to the caller's output variable.
      resultRef="${table[$cand]}"
      return 0
    fi
    [[ $cand == */* ]] || return 1
    cand="${cand%/*}"
  done
}

# __symlinkJoinResolveCollision strategyName relPath existing new
# Runs one strategy and replaces existing with its output. Failures are accumulated.
__symlinkJoinResolveCollision() {
  local -r strategyName="$1" rel="$2" dest="$3" src="$4"
  local mergeOut

  # Merges are sequential, so a counter gives each strategy a fresh scratch path.
  mergeOut="${TMPDIR:-/tmp}/symlinkJoin-merge.$((++mergeCount))"
  # Isolate strategy state and keep it from consuming the caller's find stream.
  # shellcheck disable=SC2154 # Declared by __structuredAttrs.
  if ! mergeExisting="$dest" mergeNew="$src" mergeOut="$mergeOut" \
    bash -euo pipefail -c "${strategies[$strategyName]}" </dev/null; then
    __symlinkJoinRefuse "$rel" "strategy '$strategyName' failed while merging '$rel'"
    rm -rf -- "$mergeOut"
    return 0
  fi

  # A symlink back to mergeExisting selects that entry without changing its type or mode. This is
  # how keepExisting works. Every other successful strategy must produce a real regular file.
  if [[ -L $mergeOut && $(readlink -- "$mergeOut") == "$dest" ]]; then
    rm -f -- "$mergeOut"
    return 0
  elif [[ ! -f $mergeOut || -L $mergeOut ]]; then
    __symlinkJoinRefuse "$rel" "strategy '$strategyName' did not produce a regular file at \$mergeOut while merging '$rel'"
    rm -rf -- "$mergeOut"
    return 0
  fi

  # Plain redirection creates a non-executable file; retain executability from either input.
  [[ ! -x $dest && ! -x $src ]] || chmod +x -- "$mergeOut"
  mv -f -- "$mergeOut" "$dest"
  unset 'sourceSymlinks[$rel]'
}

# __symlinkJoinFlushBatch
# Creates deferred directories and leaf entries. Regular leaves become absolute links into their
# source; source symlinks are copied without dereferencing, matching lndir's link semantics.
__symlinkJoinFlushBatch() {
  ((${#newDirs[@]} == 0)) || mkdir -p -- "${newDirs[@]}"
  ((${#newLinks[@]} == 0)) || ln -s -t "$linkDir" -- "${newLinks[@]}"
  ((${#newSymlinks[@]} == 0)) || cp -P -t "$linkDir" -- "${newSymlinks[@]}"
  newDirs=() newLinks=() newSymlinks=() batchBytes=0
}

# symlinkJoin out path...
# Joins input paths into out and reports all discovered errors together. Missing inputs are
# skipped when failOnMissing is empty.
symlinkJoin() {
  (($# >= 1)) || {
    nixErrorLog "usage: symlinkJoin out path..."
    exit 1
  }

  local -r out="$1"
  shift
  mkdir -p -- "$out"

  local -a errors=() newDirs=() newLinks=() newSymlinks=()
  # shellcheck disable=SC2034 # Accessed through dynamic scope and a nameref.
  local -A badPrefixes=() sourceSymlinks=()
  # Bound each batch well below the minimum supported exec argument limit. ${#var} counts
  # characters, so allow for four-byte UTF-8 characters.
  local -i mergeCount=0 batchBytes=0
  local linkDir="" path record type rel dest src parent strategyName error _badPrefix

  for path in "$@"; do
    if [[ ! -d $path ]]; then
      [[ -z ${failOnMissing:-} ]] || errors+=("'$path' is not a directory")
      continue
    fi

    # Prefix each NUL-terminated path with its find type. `-H` follows an input that is itself a
    # directory symlink, matching lndir, without following symlinks inside it.
    while IFS= read -r -d '' record; do
      type="${record::1}" rel="${record:1}"
      dest="$out/$rel" src="$path/$rel"

      # Skip everything underneath an already-refused path.
      if ((${#badPrefixes[@]} > 0)) && __symlinkJoinLookupByPrefix "$rel" badPrefixes _badPrefix; then
        continue
      fi

      if [[ $type == d ]]; then
        # Never let mkdir -p follow an entry symlink from an earlier input.
        if [[ -L $dest || (-e $dest && ! -d $dest) ]]; then
          __symlinkJoinRefuse "$rel" "cannot join '$path': '$rel' is a directory there, but a non-directory was already placed at '$dest'"
        elif [[ ! -e $dest ]]; then
          newDirs+=("$dest")
          ((batchBytes += ${#dest} + 1, batchBytes < 16384)) || __symlinkJoinFlushBatch
        fi # else: already a real directory; nothing to create
        continue
      fi

      if [[ -d $dest && ! -L $dest ]]; then
        __symlinkJoinRefuse "$rel" "cannot join '$path': '$rel' is not a directory there, but a directory was already placed at '$dest'"
        continue
      fi

      if [[ ! -e $dest && ! -L $dest ]]; then
        # Batch leaf placement by parent directory.
        parent="${dest%/*}"
        [[ $parent == "$linkDir" ]] || __symlinkJoinFlushBatch
        linkDir="$parent"
        if [[ -L $src ]]; then
          newSymlinks+=("$src")
          sourceSymlinks["$rel"]="$(readlink -- "$src")"
        else
          newLinks+=("$src")
        fi
        ((batchBytes += ${#src} + 1, batchBytes < 16384)) || __symlinkJoinFlushBatch
        continue
      fi

      # Source symlinks are entries in their own right: only identical link text is equal. Tracking
      # them separately also handles dangling links without confusing them with regular leaves.
      if [[ -n ${sourceSymlinks[$rel]+x} || -L $src ]]; then
        if [[ -n ${sourceSymlinks[$rel]+x} && -L $src && ${sourceSymlinks[$rel]} == "$(readlink -- "$src")" ]]; then
          continue
        fi
      elif [[ $dest -ef $src ]]; then
        continue
      elif [[ -f $dest && -f $src ]] && cmp -s -- "$dest" "$src" 2>/dev/null; then
        # Equal bytes are a no-op, but executability is the union of all contributors. A symlink
        # into a non-executable store path cannot be chmodded, so select the executable source.
        if [[ ! -x $dest && -x $src ]]; then
          if [[ -L $dest ]]; then
            rm -f -- "$dest"
            ln -s -- "$src" "$dest"
          else
            chmod +x -- "$dest"
          fi
        fi
        continue
      fi

      # Different bytes or incomparable entry types require an explicit strategy.
      if ! __symlinkJoinLookupByPrefix "$rel" pathStrategies strategyName; then
        __symlinkJoinRefuse "$rel" \
          "refusing to join '$path': '$rel' collides with content already placed at '$dest'" \
          "no merge strategy is registered for '$rel' (or any of its ancestor directories) in pathStrategies"
        continue
      fi
      __symlinkJoinResolveCollision "$strategyName" "$rel" "$dest" "$src"
    done < <(
      find -H "$path" -mindepth 1 \
        -name '*~' -prune -o \
        -type d \( -name BitKeeper -o -name CVS -o -name CVS.adm -o -name .git -o -name .hg -o -name RCS -o -name SCCS -o -name .svn \) -prune -o \
        -printf '%y%P\0'
    )
    # Explicitly reap the process substitution so a failed find cannot truncate the join.
    wait "$!" || errors+=("failed to scan '$path' for entries to join")

    # Materialize this input before probing the next one for collisions.
    __symlinkJoinFlushBatch
  done

  ((${#errors[@]} > 0)) || return 0

  for error in "${errors[@]}"; do
    nixErrorLog "$error"
  done
  return 1
}
