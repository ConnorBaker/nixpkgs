# Check the inherited stdin on both the rewritten and untouched input paths.
set -eu

cp "$1" ptxas
cat > .ptxas-wrapped <<EOF
#!$BASH
set -eu
[[ ! -e /proc/self/fd/0 ]]
if [[ \$MALFORMED_PTX == true ]]; then
  [[ \$1 == input.ptx ]]
else
  grep -Fq '"/mapped/source.cu"' "\$1"
fi
EOF
chmod +x .ptxas-wrapped
export BUILD_PATH_PREFIX_MAP="/mapped=$PWD"

printf '.version 8.0\n.file 1 "%s/source.cu"\n' "$PWD" > input.ptx
MALFORMED_PTX=false ./ptxas input.ptx <&-
printf '.version 8.0\n.file 1 "%s/source.cu\\"' "$PWD" > input.ptx
MALFORMED_PTX=true ./ptxas input.ptx <&-
