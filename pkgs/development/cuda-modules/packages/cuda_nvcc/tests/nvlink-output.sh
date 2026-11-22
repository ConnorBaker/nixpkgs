nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
link() {
  nvlink --arch="$arch" caller.o answer.o -L "$cudadevrtDir" "${@:2}"
  checkNotes "$1"
}
link a -o a
link b -o=b
link c --output-file c
link d --output-file=d
link e -o ignored -o e

# Double quotes group, a backslash escapes (dropping escaped double quotes), and options files may include others.
printf '%s\n' '-o "f g"' > quoted.optf
printf '%s\n' '-o h\ i' > escaped.optf
printf '%s\n' '-o "j\"k"' > escaped-quote.optf
printf '%s\n' "-L \"$cudadevrtDir\"" '-optf quoted.optf' > nested.optf
link "f g" -optf quoted.optf
link "h i" -optf escaped.optf
link jk -optf escaped-quote.optf
link "f g" --options-file=nested.optf
link "h i" -optf nested.optf,,escaped.optf

# Only the hashes change, to e's (octal 145): the output is otherwise the same as nvlink's.
(exec -a nvlink "$toolkit/bin/.nvlink-wrapped" --arch="$arch" caller.o answer.o -L "$cudadevrtDir" -o unwrapped)
[[ $(stat -c %s a) == $(stat -c %s unwrapped) ]]
cmp -l a unwrapped > differences || true
awk '$2 != 145 { print "unexpected difference: " $0; exit 1 }' differences
if "$recordsCommandLine"; then
  [[ -s differences ]]
fi

# A host linker script is written as-is.
nvlink -ghls lcs-abs -o wrapped.ld
"$toolkit/bin/.nvlink-wrapped" -ghls lcs-abs -o unwrapped.ld
cmp wrapped.ld unwrapped.ld

nvlink --version
