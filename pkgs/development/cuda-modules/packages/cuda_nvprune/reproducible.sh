printf '%s\n' 'int example(void) { return 42; }' | "$CC" -x c -c - -o example.o
for mtime in 1470000000 1900000000; do
  touch -d "@$mtime" example.o
  ar crU "$mtime.a" example.o
  touch -d "@$mtime" "$mtime.a"
done
printf '%s\n' '-arch=sm_80 -o "from options.a"' > prune.optf
printf '%s\n' '-optf prune.optf' > nested.optf
nvprune --options-file=nested.optf 1470000000.a
nvprune -arch=sm_80 --output-file=second.a 1900000000.a
cmp 'from options.a' second.a
ar p second.a example.o > from-archive.o
cmp example.o from-archive.o
nvprune -arch=sm_80 -o standalone.o example.o
cmp example.o standalone.o
touch "$out"
