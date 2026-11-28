# shellcheck shell=bash
# Only process the outputs of derivations that acquired this as a native build input.
if [[ ${hostOffset:--1} != -1 || ${targetOffset:-0} != 0 ]]; then
    return 0
fi

if [[ ! -v cudaCompatPolicies ]]; then
    # Wait until setup hooks (including autoPatchelf) have registered their
    # post-fixups. Explicit phase lists may omit prePhases.
    preFixupHooks+=(registerCudaCompatFixup)
    declare -ag cudaCompatPolicies=()
fi
cudaCompatPolicies+=(--policy '@marker@' '@auditor@' '@lookup@' '@symbol@' '@interpreter@')

registerCudaCompatFixup() {
    if [[ -z ${cudaCompatFixupRegistered:-} ]]; then
        postFixupHooks+=(fixupCudaCompat)
        cudaCompatFixupRegistered=1
    fi
}

fixupCudaCompat() {
    local output
    local -a paths=() flags=()
    for output in $(getAllOutputNames); do
        [[ $output == stubs ]] || paths+=("${!output}")
    done
    (( ${#paths[@]} )) || return 0
    if [[ -n ${cudaCompatWrapDlopen:-} ]]; then
        flags+=(--wrap-dlopen "$cudaCompatWrapDlopen")
    fi
    '@python@' -B '@fixup@' --patchelf '@patchelf@' "${cudaCompatPolicies[@]}" "${flags[@]}" -- "${paths[@]}"
}
