BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD" nvcc -lineinfo \
  '-gencode=arch=compute_80,code=[sm_80,compute_80]' -c "$PWD/kernel.cu" -o fatbin.o
cuobjdump -ptx fatbin.o > embedded.ptx
cuobjdump -elf fatbin.o > embedded.elf
grep -F 'identifier = /usr/src/cuda-test/kernel.cu' embedded.ptx
grep -E '\.file[[:space:]]+[0-9]+ "/usr/src/cuda-test/kernel\.cu"' embedded.ptx
grep -F /usr/src/cuda-test embedded.elf
if grep -F "$PWD/kernel.cu" embedded.ptx embedded.elf; then
  nixErrorLog "fatbinary retained an explicitly remapped source path"
  exit 1
fi

# Linux limits the size of a single argv entry. An options file can hold a larger identifier.
nvcc -arch=sm_80 -ptx kernel.cu -o input.ptx
printf -v padding '%140000s' ""
printf -- '--ident="%s/%s"\n' "$PWD" "${padding// /x}" > identifier.optf
printf '%s\n' '-optf identifier.optf --image3=kind=ptx,sm=80,file=input.ptx' > fatbinary.optf
BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD" fatbinary -64 -optf fatbinary.optf --create=large.fatbin
cuobjdump -ptx large.fatbin > large.ptx
grep -q -F 'identifier = /usr/src/cuda-test/xxxxxxxx' large.ptx
