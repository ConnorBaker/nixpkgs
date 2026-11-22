for dir in first second; do
  mkdir "$dir"
  cp templates.cu "$dir"
  (
    cd "$dir"
    export BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD"
    nvcc -arch="$arch" -c templates.cu -o normal.o
    nvcc -arch="$arch" -rdc=true -lineinfo -c "$PWD/templates.cu" -o relocatable.o
    # The source path also contributes to symbol names when the seed is explicit.
    nvcc -arch="$arch" --frandom-seed=123 -lineinfo -ptx templates.cu -o output.ptx
  )
done

cmp first/normal.o second/normal.o
cmp first/relocatable.o second/relocatable.o
cmp first/output.ptx second/output.ptx
grep -F '"/usr/src/cuda-test/templates.cu"' first/output.ptx
