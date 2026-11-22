# Two sources with the same name cannot share a directory for their intermediate files. Without -c, their objects
# are in that directory too.
mkdir a b
echo 'int a() { return 1; }' > a/same.cu
echo 'int a(); int main() { return a(); }' > b/same.cu
nvcc -arch="$arch" a/same.cu b/same.cu -o result

# nvcc uses the directory that the caller passes, and the wrapper does not remove it. CMake depends on this when
# it identifies nvcc.
mkdir kept
nvcc -arch="$arch" --keep --keep-dir kept -c kernel.cu -o kernel.o
[[ -e kept/kernel.ptx ]]
nvcc -arch="$arch" -rdc=true --keep -c caller.cu -o caller.o
[[ -e caller.ptx ]]
rm caller.ptx
NVCC_APPEND_FLAGS=$'-O2\t--keep' nvcc -arch="$arch" -rdc=true -c caller.cu -o caller.o
[[ -e caller.ptx ]]
NVCC_APPEND_FLAGS="--keep --keep-dir=kept" nvcc -arch="$arch" -c answer.cu -o answer.o
[[ -e kept/answer.ptx ]]
printf '%s\n' "-arch=$arch --keep --keep-dir=kept -c \"options source.cu\"" > nvcc.optf
cp kernel.cu "options source.cu"
nvcc --options-file=nvcc.optf -o options.o
[[ -e "kept/options source.ptx" ]]
if "$seeds"; then
  # nvcc uses the seed that the caller passes.
  nvcc -arch="$arch" --frandom-seed=1 -c templates.cu -o seed-1.o
  nvcc -arch="$arch" --frandom-seed=2 -c templates.cu -o seed-2.o
  NVCC_PREPEND_FLAGS=--frandom-seed=1 nvcc -arch="$arch" -c templates.cu -o seed-3.o
  if cmp --silent seed-1.o seed-2.o || ! cmp seed-1.o seed-3.o; then
    nixErrorLog "expected the seed passed to nvcc to be used"
    exit 1
  fi
fi

# The wrapper exits with the status of nvcc, and removes the directory when nvcc fails too.
echo 'syntax error' > broken.cu
expected=0
(exec -a nvcc "$toolkit/bin/.nvcc-wrapped" -arch="$arch" -c broken.cu -o broken.o) || expected=$?
status=0
nvcc -arch="$arch" -c broken.cu -o broken.o || status=$?
if [[ $expected == 0 || $status != "$expected" ]]; then
  nixErrorLog "expected nvcc to exit with its status ($expected), got $status"
  exit 1
fi

# A configure check can pass an output that is not in a writable directory.
nvcc -arch="$arch" -c kernel.cu -o /dev/null

nvcc --version
nvcc -arch="$arch" -E kernel.cu > /dev/null

# The vendor driver needs to find the installed profile even through an external symlink.
mkdir linked
ln -s "$toolkit/bin/nvcc" linked/nvcc
env -i TMPDIR="$TMPDIR" ./linked/nvcc -arch="$arch" --ptx kernel.cu -o linked.ptx

checkScratchCleanup
