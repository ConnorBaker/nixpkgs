nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
# NOTE: nvlink only links inputs named *.cubin as cubins, and before CUDA 13, a relocatable link of relocatable
# device code requires libcudadevrt.
(exec -a nvlink "$toolkit/bin/.nvlink-wrapped" --arch="$arch" -r caller.o answer.o -L "$cudadevrtDir" -lcudadevrt \
  -o input.cubin)
nvlink --arch="$arch" input.cubin -L "$cudadevrtDir" -o result
checkNotes result
if "$preservesInputNotes" && (( $(nvlinkOptions result | wc -l) < 2 )); then
  nixErrorLog "expected nvlink to keep the note of its input"
  exit 1
fi
