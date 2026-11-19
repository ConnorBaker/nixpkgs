# shellcheck shell=bash
[[ -z ${strictDeps-} ]] || (( hostOffset < 0 )) || return 0
source @nvccPrefix@/nix-support/role.bash

_nvccSetup() {
    local targetOffset="$targetOffset"
    # Non-strict builds use the ordinary unsuffixed compiler environment.
    [[ -n ${strictDeps-} ]] || targetOffset=0
    getTargetRoleWrapper

    # Register the backend's dependency collectors without activating its tools.
    # Each wrapper owns its callbacks; flags still share ordinary per-role NIX_*
    # variables, including when the enclosing project uses stdenvNoCC.
    source @bintools@/nix-support/add-env-hooks.sh
    source @cc@/nix-support/add-env-hooks.sh

    # Discover the compiler here; its wrapper owns the backend default.
    local role_post
    getTargetRole
    local cudacxx="CUDACXX${role_post}"
    export "${cudacxx}=${!cudacxx:-@nvccPrefix@/bin/nvcc}"
    local cudaHostCxx="CUDAHOSTCXX${role_post}"
    # Defined-but-empty makes legacy FindCUDA defer to NVCC instead of adding
    # -ccbin for the project's C compiler. Modern CMake also defers when empty.
    export "${cudaHostCxx}=${!cudaHostCxx-}"

    if [[ -z $role_post ]]; then
        # Give the enclosing compiler or an explicit postHook first choice.
        postHooks+=('source @cc@/nix-support/set-default-hardening.sh')
        # Legacy FindCUDA uses CUDA_BIN_PATH before PATH and ignores CUDACXX.
        : "${CUDAToolkit_ROOT:=@nvccPrefix@}" "${CUDA_BIN_PATH:=@nvccPrefix@/bin}"
        export CUDAToolkit_ROOT CUDA_BIN_PATH
    fi

    export NIX_CUDA_DONT_COMPRESS_FATBINS="${dontCompressCudaFatbins-${dontCompressFatbin-}}"
    # NVCC reads flag text from the environment. Bash cannot export indexed arrays.
    local IFS=' ' name value
    for name in NVCC_PREPEND_FLAGS NVCC_APPEND_FLAGS; do
        if [[ $(declare -p "$name" 2>/dev/null) == 'declare -a'* ]]; then
            local -n flags="$name"
            value="${flags[*]}"
            unset -v "$name"
            printf -v "$name" %s "$value"
        fi
        export "$name"
    done
    : "${NVCC_PREPEND_FLAGS=}"
}
_nvccSetup
unset -f _nvccSetup
