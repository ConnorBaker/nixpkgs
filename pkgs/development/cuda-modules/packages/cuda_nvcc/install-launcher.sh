# Install a static launcher and keep the vendor executable beside it.
installCudaLauncher() (
    local cc=$1 runner=$2 program=$3 launcher
    shift 3
    launcher=$(mktemp) || return
    trap 'rm -f -- "$launcher"' EXIT
    set -o pipefail
    # The source generator reads unset local variables.
    (set +u; makeDocumentedCWrapper "$runner" --inherit-argv0 "$@" --add-flag "$program") |
        NIX_CFLAGS_COMPILE= NIX_CFLAGS_LINK= "$cc" -Os -static -s -x c -o "$launcher" - || return
    chmod +x "$launcher" || return
    installAdjacentWrapper "$program" "$launcher"
)
