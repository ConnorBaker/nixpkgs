member=example-object-with-long-name.o
printf '%s\n' 'int example(void) { return 42; }' | "$CC" -x c -c - -o "$member"
owner=1234
for mtime in 1470000000 1900000000; do
  touch -d "@$mtime" "$member"
  ar crU "$mtime.a" "$member"
  read -r _ memberOffset < <(ar tO "$mtime.a")
  # ar reports the payload offset. The UID and GID start 28 bytes into the 60-byte header.
  printf '%-6d%-6d' "$owner" "$owner" \
    | dd of="$mtime.a" bs=1 seek="$((memberOffset - 60 + 28))" conv=notrunc status=none
  touch -d "@$mtime" "$mtime.a"
  ((owner += 1))
done
printf '%s\n' '-arch=sm_80 -o "from options.a"' > prune.optf
printf '%s\n' '-optf prune.optf' > nested.optf
nvprune --options-file=nested.optf 1470000000.a
nvprune -arch=sm_80 --output-file=second.a 1900000000.a
cmp 'from options.a' second.a
ar p second.a "$member" > from-archive.o
cmp "$member" from-archive.o
nvprune -arch=sm_80 -o standalone.o "$member"
cmp "$member" standalone.o
touch "$out"
