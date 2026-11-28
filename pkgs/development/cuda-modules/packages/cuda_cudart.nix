# TODO(@connorbaker): cuda_cudart.dev depends on crt/host_config.h, which is from
# (getDev cuda_nvcc). It would be nice to be able to encode that.
{
  addDriverRunpath,
  autoAddCudaCompatRunpath,
  buildRedist,
  cccl,
  cuda_crt,
  cuda_nvcc,
  cudaAtLeast,
  lib,
  pkg-config,
  removeStubsFromRunpathHook,
}:
buildRedist (finalAttrs: {
  redistName = "cuda";
  pname = "cuda_cudart";

  # Keep the full SDK in one directory: CMake looks for static and shared
  # libraries together. Only development consumers need the native fixup tools.
  outputs = [ "out" ] ++ lib.optional autoAddCudaCompatRunpath.enableHook "dev";
  moveToDev = false;

  # We have stubs but we don't have an explicit stubs output.
  includeRemoveStubsFromRunpathHook = true;

  # CMake and the linker need these when callers split them into separate outputs.
  propagatedBuildOutputs = lib.intersectLists finalAttrs.outputs [
    "static"
    "stubs"
  ];

  # The hook runs on the build machine and writes paths for the host. Keep this
  # package set's hook when mkDerivation splices propagated native inputs.
  propagatedNativeBuildInputs = lib.optional autoAddCudaCompatRunpath.enableHook autoAddCudaCompatRunpath.outPath;

  propagatedBuildInputs =
    # TODO(@SomeoneSerge): Consider propagating `crt/host_config.h`, but only
    # once we managed to split out `cuda_nvcc`'s headers into a separate output
    #
    # TODO(@connorbaker): Check that the dependency offset for this is correct.
    #
    # [ (lib.getInclude cuda_nvcc) ]

    # TODO(@connorbaker): From CUDA 13.0, crt/host_config.h is in cuda_crt
    lib.optionals (cudaAtLeast "13.0") [ (lib.getOutput "include" cuda_crt) ]
    # Add the dependency on CCCL's include directory.
    # - nv/target
    # TODO(@connorbaker): Check that the dependency offset for this is correct.
    ++ [ (lib.getOutput "include" cccl) ];

  allowFHSReferences = false;

  # buildRedist has collected the vendor's .pc files in share/pkgconfig.
  postPatch = ''
    local pc
    for pc in share/pkgconfig/{cuda,cudart}-*.pc; do
      [[ -f $pc ]] || continue
      sed -i \
        -e '/^cudaroot\s*=/d' \
        -e "s|''${!outputDev:?}|$out|g" \
        -e '/^Libs\s*:/s|$| -Wl,-rpath,${addDriverRunpath.driverLink}/lib|' "$pc"
      if [[ $pc == share/pkgconfig/cuda-* ]]; then
        # Since 13.4 NVIDIA includes /stubs in Libs. Point both layouts to the stub output.
        sed -i \
          -e "s|^libdir\s*=.*/lib\$|libdir=''${!outputStubs:?}/lib/stubs|" \
          -e 's|-L''${libdir}/stubs\b|-L''${libdir}|' "$pc"
      fi
    done
  '';

  # Namelink may not be enough, add a soname.
  # Cf. https://gitlab.kitware.com/cmake/cmake/-/issues/25536
  # NOTE: Relative symlinks is fine since this is all within the same output.
  postInstall = ''
    pushd "''${!outputStubs:?}/lib/stubs" >/dev/null
    if [[ -f libcuda.so && ! -f libcuda.so.1 ]]; then
      nixLog "creating versioned symlink for libcuda.so stub"
      ln -srv libcuda.so libcuda.so.1
    fi
    popd >/dev/null
  '';

  postFixup =
    lib.optionalString autoAddCudaCompatRunpath.enableHook ''
      local archive="''${!outputStatic:?}/lib/libcudart_static.a"
      if [[ -f $archive ]]; then
        "$OBJCOPY" --redefine-sym "dlopen=${autoAddCudaCompatRunpath.driverLookup.symbol}_archive" "$archive" "$archive.new"
        "$AR" rDs "$archive.new" "${autoAddCudaCompatRunpath.driverLookup.staticObject}"
        mv "$archive.new" "$archive"
      fi
    ''
    + lib.optionalString (lib.elem "dev" finalAttrs.outputs) ''
      # Expose the SDK to getDev callers. Only out/lib has the runtime SONAME,
      # so ordinary linkers and RPATH shrinking drop dev (and its build tools).
      mkdir -p "$dev/lib" "$out/nix-support"
      # SDK joins merge directories and link individual files from each component.
      cp -rs "$out/include" "$out/share" "$dev/"
      cp -rs "''${!outputStubs:?}/lib/stubs" "$dev/lib/"
      ln -s "''${!outputLib:?}"/lib/*.so "''${!outputStatic:?}"/lib/*.a "$dev/lib/"
      # Keep the CRT and CCCL headers available to consumers of the explicit out output.
      cat "$dev/nix-support/propagated-build-inputs" >> "$out/nix-support/propagated-build-inputs"
      echo "$out ${lib.getDev removeStubsFromRunpathHook}" >> "$dev/nix-support/propagated-build-inputs"
    '';

  # Link through the installed package config files, which fails if their library paths are wrong.
  nativeInstallCheckInputs = [ pkg-config ];
  postInstallCheck = ''
    export PKG_CONFIG_PATH="$out/share/pkgconfig"
    echo 'int main(void) { return 0; }' | $CC -x c - -o /dev/null $(pkg-config --libs cuda cudart)
  '';

  # "Never again", cf. https://github.com/NixOS/nixpkgs/pull/457424
  disallowedRequisites = [ (lib.getBin cuda_nvcc) ];

  meta = {
    description = "CUDA Runtime";
    pkgConfigModules = [
      "cuda"
      "cudart"
    ];
  };
})
