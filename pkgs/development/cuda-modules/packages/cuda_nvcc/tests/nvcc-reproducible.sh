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

checkScratchCleanup
