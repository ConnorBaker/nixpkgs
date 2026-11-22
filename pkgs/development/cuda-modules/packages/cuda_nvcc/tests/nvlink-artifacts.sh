# Hashes of store paths are blanked in .note.nv.tkinfo sections, and only there.
hash=0123456789abcdfghijklmnpqrsvwxyz
printf 'nvlink\0-L %s/%s-x/lib\0' "$storeDir" "$hash" > note
echo 'int x;' | "$CC" -c -x c - -o empty.o
objcopy --add-section .note.nv.tkinfo=note --add-section .other=note empty.o note.o
FAKE=write FAKE_CONTENTS=note.o ./nvlink -o scrubbed.o
objcopy --dump-section .note.nv.tkinfo=scrubbed --dump-section .other=other scrubbed.o
sed "s/$hash/$(printf 'e%.0s' {1..32})/" note > expected
cmp scrubbed expected
cmp other note
# With many sections, the number of sections and the index of the section names are in the first section header.
python3 -P "$extendedElf" note.o extended.o
readelf --file-header extended.o | grep -F 'Number of section headers:         0 ('
FAKE=write FAKE_CONTENTS=extended.o ./nvlink -o scrubbed-extended.o
expect "$(grep -a -o -F "$hash" scrubbed-extended.o | wc -l)" 1 "hashes left in a file with many sections"
# The output is left as-is if nvlink fails.
expect "$(FAKE=write FAKE_CONTENTS=note.o FAKE_STATUS=1 status ./nvlink -o failed.o)" 1 "nvlink's exit status"
cmp failed.o note.o

# Anything else the wrapper doesn't expect fails the link, before nvlink runs where possible.
printf 'INPUT(%s/%s-x)\n' "$storeDir" "$hash" > text
FAKE=write FAKE_CONTENTS=text expectFailure "the output isn't an ELF file, but refers to the Nix store" \
  ./nvlink -o result
printf '\x7fELF' > truncated
FAKE=write FAKE_CONTENTS=truncated expectFailure "the output is a malformed ELF file" ./nvlink -o result
{ printf '\x7fELF\x01\x01'; head -c 58 /dev/zero; } > elf32
FAKE=write FAKE_CONTENTS=elf32 expectFailure "the output isn't a 64-bit little-endian ELF file" ./nvlink -o result
FAKE=exit FAKE_STATUS=0 expectFailure "/dev/null is not a regular file" ./nvlink -o /dev/null
echo kept > kept
FAKE=exit FAKE_STATUS=0 expectFailure "nvlink didn't write kept" ./nvlink -o kept
expect "$(cat kept)" kept "an output nvlink didn't write"
rm log
FAKE=exit FAKE_STATUS=0 expectFailure "-o is missing its value" ./nvlink -o
printf '%s' '-o "unterminated' > unterminated.optf
FAKE=exit FAKE_STATUS=0 expectFailure "an options file ends in a backslash or a quotation" \
  ./nvlink -optf unterminated.optf
printf '%s' '-optf self.optf' > self.optf
FAKE=exit FAKE_STATUS=0 expectFailure "options files are nested too deeply" ./nvlink -optf self.optf
FAKE=exit FAKE_STATUS=0 expectFailure "options file /dev/fd/" ./nvlink -optf <(echo -o result)
FAKE=exit FAKE_STATUS=0 expectFailure "options file missing.optf is missing or not a regular file" \
  ./nvlink -optf missing.optf
if [[ -e log ]]; then
  nixErrorLog "expected nvlink not to run"
  exit 1
fi
