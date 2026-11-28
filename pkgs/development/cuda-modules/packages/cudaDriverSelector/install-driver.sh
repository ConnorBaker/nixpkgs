# shellcheck shell=bash
output=$1

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"

name=${output##*/}
hash=${name%%-*}
private=$output/libexec/driver
export CUDA_COMPAT_MANIFEST="$output/nix-support/nix-cuda-compat"
export CUDA_LOOKUP_PATH="$output/libexec/libnix-cuda-driver-lookup.so"
export CUDA_COMPANIONS="$work/companions"
export CUDA_LOOKUP_SYMBOL="nix_cuda_dlopen_$hash" CUDA_COMPANION_SYMBOL="nix_cuda_companion_dlopen_$hash"
"${manifest[@]}" "$output" --wrap "$patchelf" "$CUDA_LOOKUP_PATH" "$CUDA_COMPANION_SYMBOL" > "$CUDA_COMPANIONS"
CUDA_COMPAT_DRIVER=$(realpath -e "$output/compat/libcuda.so.1")
export CUDA_COMPAT_DRIVER
mkdir -p "$private"
ln -s "$CUDA_COMPAT_DRIVER" "$private/libcuda.so.1"

"$rustc" nix_cuda_driver_lookup explicit_tail_calls "$lookupRs" -o lookup.o
printf '{ global: %s; %s; nix_cuda_try_driver; local: *; };\n' "$CUDA_LOOKUP_SYMBOL" "$CUDA_COMPANION_SYMBOL" > exports
"$cc" -shared -s -Wl,-z,now,-z,defs,--gc-sections,--version-script=exports \
    lookup.o "$policy" -Wl,--push-state,--no-as-needed \
    -l:libdl.so.2 -Wl,--pop-state -o "$CUDA_LOOKUP_PATH"
# stdenv also passes its output's lib directory to the linker.
"$patchelf" --force-rpath --set-rpath "$private" "$CUDA_LOOKUP_PATH"
CUDA_LOOKUP_SYMBOL="${CUDA_LOOKUP_SYMBOL}_archive" "$rustc" nix_cuda_static_lookup explicit_tail_calls \
    --cfg static_cudart "$lookupRs" -o "$output/libexec/nix-cuda-static-lookup.o"
