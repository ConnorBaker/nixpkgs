aliasDir="$PWD/cuda-source"
for dir in first second-longer; do
  mkdir -p "$dir/kept"
  cp templates.cu "$dir"
  ln -sfn "$PWD/$dir" "$aliasDir"
  (
    cd "$dir"
    export BUILD_PATH_PREFIX_MAP="$aliasDir=$PWD"
    nvcc -arch="$arch" --keep --keep-dir=kept -G -src-in-ptx -ptx templates.cu -o debug.ptx
    nvcc -arch="$arch" -G -cubin "$aliasDir/templates.cu" -o debug.cubin
    nvcc -arch="$arch" -dlto -ltoir "$aliasDir/templates.cu" -o device.ltoir

    BUILD_PATH_PREFIX_MAP="/proc/self/cwd=$PWD" \
      nvcc -arch="$arch" -lineinfo -dlto -ltoir templates.cu -o proc-cwd.ltoir
  )
done

for file in debug.ptx debug.cubin device.ltoir proc-cwd.ltoir; do
  cmp "first/$file" "second-longer/$file"
done
readelf --debug-dump=info first/debug.cubin | grep -F DW_AT_comp_dir | grep -F -- "$aliasDir"
