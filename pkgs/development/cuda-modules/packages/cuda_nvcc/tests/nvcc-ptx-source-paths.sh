mkdir 'source tree' outputs
cp kernel.cu 'source tree/kernel.cu'
cp kernel.cu 'source tree/second.cu'
export BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD/source tree"

# With -odir, nvcc writes one PTX file per input in the named directory.
printf '%s\n' '--ptx -lineinfo -odir outputs "source tree/kernel.cu" "source tree/second.cu"' > compile.optf
nvcc -arch=sm_80 --options-file=compile.optf
for file in kernel second; do
  grep -F "\"/usr/src/cuda-test/$file.cu\"" "outputs/$file.ptx"
  if grep -F "$PWD/source tree/" "outputs/$file.ptx"; then
    nixErrorLog "nvcc retained a remapped source path in standalone PTX"
    exit 1
  fi
done
ptxas -arch=sm_80 -o shortened.cubin outputs/kernel.ptx

nvcc -arch=sm_80 --ptx -lineinfo 'source tree/kernel.cu'
grep -F '"/usr/src/cuda-test/kernel.cu"' kernel.ptx

# An explicit filename overrides -odir. The replacement may grow the file.
target="$PWD/canonical/source/tree"
BUILD_PATH_PREFIX_MAP="$target=$PWD/source tree" nvcc -arch=sm_80 --ptx -lineinfo \
  -odir outputs -o explicit 'source tree/kernel.cu'
grep -F "\"$target/kernel.cu\"" explicit
ptxas -arch=sm_80 -o lengthened.cubin explicit

# A stream still goes directly to the caller.
nvcc -arch=sm_80 --ptx -lineinfo -o - 'source tree/kernel.cu' > streamed.ptx
grep -F "\"$PWD/source tree/kernel.cu\"" streamed.ptx
