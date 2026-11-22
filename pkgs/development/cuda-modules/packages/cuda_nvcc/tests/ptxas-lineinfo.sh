mkdir 'source tree'
printf '%s\n' '// device source' > 'source tree/test.cu'
cat > input.ptx << EOF
.version 8.0
.target sm_80
.address_size 64
.file 1 "$PWD/source tree/test.cu"
.visible .entry test() {
  .loc 1 1 0
  ret;
}
EOF
printf '%s\n' '-arch=sm_80 -lineinfo "input.ptx" -o "file output.cubin"' > ptxas.optf

# Cross a ULEB128 size boundary in the raw line table.
for mtime in 1 1900000000; do
  touch -d "@$mtime" 'source tree/test.cu'
  BUILD_PATH_PREFIX_MAP= ptxas --options-file=ptxas.optf
  mv 'file output.cubin' "$mtime.cubin"
done
cmp 1.cubin 1900000000.cubin
readelf --debug-dump=rawline 1.cubin | grep -F "$PWD/source tree"

cp input.ptx 'input=with spaces.ptx'
printf '%s\n' '-lineinfo "input=with spaces.ptx" -o "mapped.cubin"' > inner.optf
printf '%s\n' '-arch=sm_80 --options-file=inner.optf' > outer.optf
BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD/source tree" ptxas -optf outer.optf
readelf --debug-dump=rawline mapped.cubin > mapped.txt
grep -F /usr/src/cuda-test mapped.txt
grep -F test.cu mapped.txt
if grep -F "$PWD/source tree" mapped.txt; then
  nixErrorLog "ptxas retained an explicitly remapped source path"
  exit 1
fi

# Nonzero timestamps explicitly set by the PTX generator carry through.
sed 's/test\.cu"$/test.cu", 12345, 42/' input.ptx > explicit.ptx
ptxas -arch=sm_80 -lineinfo -o explicit.cubin explicit.ptx
readelf --debug-dump=rawline explicit.cubin | grep -E '12345[[:space:]]+42[[:space:]]+test\.cu'

# PTX allows hexadecimal and binary integer literals with an unsigned suffix.
sed -e 's/\.file 1 /.file 0x1 /' -e 's/test\.cu"$/test.cu", 0B0U, 42/' input.ptx > zero.ptx
ptxas -arch=sm_80 -lineinfo -o zero.cubin zero.ptx
if "$checksZeroTimestamp"; then
  readelf --debug-dump=rawline zero.cubin | grep -E '[[:space:]]1[[:space:]]+42[[:space:]]+test\.cu'
fi
