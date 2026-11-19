#!@shell@
set -e
source @wrapperUtils@

# NVCC exports its computed profile to subprocesses. A nested compiler must
# start with its own SDK paths; caller options use -I/-L and NVCC_*_FLAGS.
unset INCLUDES SYSTEM_INCLUDES LIBRARIES NVLINK_FLAGS

# NVCC selects its backend afresh; an enclosing driver's prepared request does not apply.
wrapperClear
unset wrapperLinkerFlavor

# cc-wrapper and bintools-wrapper share their salt between compiler versions
# targeting the same CPU. Narrow their roles to this NVCC invocation so a
# native BUILD compiler cannot contribute dependency flags to a native HOST compiler.
for role in BUILD HOST TARGET; do
    marker="NIX_NVCC_TARGET_${role}_@suffixSalt@"
    export "NIX_CC_WRAPPER_TARGET_${role}_@ccSuffixSalt@=${!marker-}"
    export "NIX_BINTOOLS_WRAPPER_TARGET_${role}_@bintoolsSuffixSalt@=${!marker-}"
done

accumulateRoles
# Outside a stdenv activation, use the wrapper's own backend and the ordinary
# environment.
if (( ${#role_suffixes[@]} == 0 )); then
    role_suffixes=('')
    export NIX_NVCC_TARGET_HOST_@suffixSalt@=1
    export NIX_CC_WRAPPER_TARGET_HOST_@ccSuffixSalt@=1
    export NIX_BINTOOLS_WRAPPER_TARGET_HOST_@bintoolsSuffixSalt@=1
fi

# Recover caller inputs before a nested invocation selects its roles. Keep
# intervening caller edits, including an explicit empty or unset value.
restoreProjectedVar NVCC_CCBIN NIX_NVCC_CCBIN
for role in _FOR_BUILD '' _FOR_TARGET; do
    restoreProjectedVar "NIX_LDFLAGS_AFTER$role" "NIX_NVCC_LDFLAGS_AFTER$role"
done
mangleVarSingle NVCC_CCBIN "${role_suffixes[@]}"

# NVCC_CCBIN is a default: explicit --compiler-bindir arguments (including
# those in the caller's NVCC_PREPEND_FLAGS) retain NVCC's normal precedence.
exportProjectedVar NVCC_CCBIN "${wrapper_NVCC_CCBIN:-@hostCompiler@}" NIX_NVCC_CCBIN
# nvlink also uses grep, sed and tr to generate a host linker script.
export PATH="@nvccPrefix@/nix-support/bin${PATH:+:$PATH}:@fallbackPath@"

# Append after every active role's caller flags. The ordinary backend linker
# consumes these flags; nvlink continues to receive only library search paths.
ldAfterVariable="NIX_LDFLAGS_AFTER${role_suffixes[-1]}"
exportProjectedVar "$ldAfterVariable" "${!ldAfterVariable-} -rpath @driverRunpath@" "NIX_NVCC_LDFLAGS_AFTER${role_suffixes[-1]}"
unset ldAfterVariable

libraryFlags=()
# The backend wrapper already reads NIX_CFLAGS_COMPILE and NIX_LDFLAGS.
# NVCC also invokes nvlink directly, so its device linker needs the same -L
# search paths. Other host linker options remain the backend's responsibility.
# Project caller inputs only. The selected backend owns its CPU library defaults.
mangleVarList NIX_LDFLAGS_BEFORE "${role_suffixes[@]}"
mangleVarList NIX_LDFLAGS "${role_suffixes[@]}"
mangleVarList NIX_LDFLAGS_AFTER "${role_suffixes[@]}"
read -r -d '' -a ldFlags <<< "$wrapper_NIX_LDFLAGS_BEFORE $wrapper_NIX_LDFLAGS $wrapper_NIX_LDFLAGS_AFTER" || true
for ((i=0; i<${#ldFlags[@]}; i++)); do
    ldFlag=${ldFlags[i]}
    case "$ldFlag" in
        -library-path|-library-path=*)
            if linkerOptionTakesOperand -library-path; then ldFlag=-$ldFlag; fi ;;
    esac
    case "$ldFlag" in
        --) break ;;
        -L|--library-path) directory=${ldFlags[++i]} ;;
        -L?*) directory=${ldFlag#-L} ;;
        --library-path=*) directory=${ldFlag#*=} ;;
        *)
            if linkerOptionTakesOperand "$ldFlag"; then ((i+=1)); fi
            continue ;;
    esac
    # GNU ld resolves these prefixes against its sysroot. nvlink can
    # interpret -L=/path as a search of /path on the build machine.
    case "$directory" in
        ''|=*|'$SYSROOT'*) continue ;;
    esac
    # Both the shell and nvlink's options-file reader accept double quotes.
    # Escape the characters the shell would still interpret inside them.
    directory=${directory//\\/\\\\}
    directory=${directory//\"/\\\"}
    directory=${directory//\$/\\\$}
    directory=${directory//\`/\\\`}
    libraryFlags+=("\"-L$directory\"")
done
# The native device-only profile channel follows explicit NVCC paths and SDK
# defaults.
export NIX_NVCC_LIBRARIES="${libraryFlags[*]}"
[[ -n ${NIX_CUDA_DONT_COMPRESS_FATBINS-} ]] || set -- -Xfatbin=-compress-all "$@"
# CMake identifies NVIDIA from the "nvcc:" prefix in --version output.
# Use the absolute public name: NVCC also locates its profile through argv[0],
# and another CUDA version may appear first on PATH.
exec -a @nvccPrefix@/bin/nvcc @nvcc@ "$@"
