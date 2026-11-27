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

# With an explicit source language, separate option operands must stay out of
# the source list so the wrapper edits only the PTX files that nvcc produces.
nvcc -arch=sm_80 --ptx -lineinfo -x cu --threads 2 --split-compile 2 \
  -DPROBE -O2 --forward-unknown-to-host-compiler -Wno-unused-variable \
  --std c++17 --default-stream per-thread 'source tree/kernel.cu'
grep -F '"/usr/src/cuda-test/kernel.cu"' kernel.ptx

# A missing optional operand must leave the following -x visible to the wrapper.
cp kernel.cu 'source tree/no-extension'
for flag in -Ofc -hls; do
  nvcc -arch=sm_80 --ptx -lineinfo "$flag" -x cu -o optional.ptx 'source tree/no-extension'
  grep -F '"/usr/src/cuda-test/no-extension"' optional.ptx
done

# An explicit filename overrides -odir. The replacement may grow the file.
target="$PWD/canonical/source/tree"
BUILD_PATH_PREFIX_MAP="$target=$PWD/source tree" nvcc -arch=sm_80 --ptx -lineinfo \
  -odir outputs -o explicit 'source tree/kernel.cu'
grep -F "\"$target/kernel.cu\"" explicit
ptxas -arch=sm_80 -o lengthened.cubin explicit

# A requested remapping applies when writing PTX to stdout as well.
nvcc -arch=sm_80 --ptx -lineinfo -o - 'source tree/kernel.cu' > streamed.ptx
grep -F '"/usr/src/cuda-test/kernel.cu"' streamed.ptx

# Queries take precedence over compilation flags and only write stdout.
for query in --list-gpu-arch --list-gpu-code; do
  nvcc "$query" --ptx -o query.ptx 'source tree/kernel.cu' > query.txt
  [[ -s query.txt && ! -e query.ptx ]]
done
