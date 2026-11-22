# Runs a command twice and compares the two outputs.
twice() {
  local output="$1"
  shift
  "$@" -o "$output"
  mv "$output" first
  "$@" -o "$output"
  if ! cmp first "$output"; then
    nixErrorLog "$* wrote a different $output the second time"
    exit 1
  fi
}
twice kernel.o nvcc -arch="$arch" -c kernel.cu
twice debug.o nvcc -arch="$arch" -g -c kernel.cu
twice relocatable.o nvcc -arch="$arch" -rdc=true -c caller.cu
# CMake compiles sources that are not named *.cu in this way.
cp kernel.cu kernel.cpp
twice language.o nvcc -arch="$arch" -x cu -c kernel.cpp
sources=(kernel.cu)
if "$seeds"; then
  sources+=(templates.cu)
fi
cp "${sources[-1]}" kernel-no-extension
twice extensionless.o nvcc -arch="$arch" -x cu -c kernel-no-extension
mkdir pre-include
printf '%s\n' '#define PRE_INCLUDED 1' > pre-include/kernel.cu
twice pre-include.o nvcc -arch="$arch" -include pre-include/kernel.cu -c kernel.cu
cp kernel.cu "source with spaces.cu"
printf '%s\n' "-arch=$arch -g -c \"source with spaces.cu\"" > nvcc.optf
twice options.o nvcc -optf nvcc.optf
# Without -c, the objects are intermediate files as well.
twice result nvcc -arch="$arch" kernel.cu
if "$seeds"; then
  twice templates.o nvcc -arch="$arch" -c templates.cu
fi

# Without --keep, nvcc names its intermediate files tmpxft_<pid>_...
if grep --text --fixed-strings tmpxft ./*.o result; then
  nixErrorLog "an output contains the name of a temporary file"
  exit 1
fi

# nvcc without the wrapper must still write different objects. If it does not, the wrapper is no longer needed.
for source in "${sources[@]}"; do
  (exec -a nvcc "$toolkit/bin/.nvcc-wrapped" -arch="$arch" -c "$source" -o unwrapped-1.o)
  (exec -a nvcc "$toolkit/bin/.nvcc-wrapped" -arch="$arch" --keep --keep-dir "$(mktemp -d)" -c "$source" \
    -o unwrapped-2.o)
  if cmp --silent unwrapped-1.o unwrapped-2.o; then
    nixErrorLog "expected nvcc to name the object of $source after a temporary file"
    exit 1
  fi
  if [[ $source == templates.cu ]]; then
    (exec -a nvcc "$toolkit/bin/.nvcc-wrapped" -arch="$arch" --keep --keep-dir "$(mktemp -d)" -c "$source" \
      -o unwrapped-3.o)
    if cmp --silent unwrapped-2.o unwrapped-3.o; then
      nixErrorLog "expected nvcc to name the symbols of $source after its process ID"
      exit 1
    fi
  fi
done

checkScratchCleanup
