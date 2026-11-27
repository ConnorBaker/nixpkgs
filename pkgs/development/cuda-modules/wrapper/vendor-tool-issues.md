# NVIDIA tool documentation discrepancies

These observations come from unwrapped Linux toolkit binaries. The versions
refer to the tested binaries. Add an NVIDIA report link or ID when available.
The entries below currently have local reproductions.
[NVIDIA bug reporting](https://developer.nvidia.com/cuda/faq)

| Tool and version | Documentation | Observed behavior |
| --- | --- | --- |
| ptxas 12.6.85 and 13.5.37 | Help and the manual show the same operand syntax for `--opt-level <N>` and `-O`. [Optimization level](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#opt-level-n-o) | `--opt-level 0` and `-O0` work. Bare `-O` leaves the following input filename in place. With `-O 0`, the assembler attempts to open a file named `0`. |
| ptxas 13.5.37 | Help omits `--nv-host` and `-nv-host`. | Both take a file path and embed its bytes in the cubin's `.nv.host` section. Neither spelling occurs as a literal string in the vendor executable. The wrapper discovers the operand on use. 12.6.85 rejects these spellings. |
| nvcc 13.5.37 | Help and the manual show `-Ofc` with a level. The manual gives the default when fast compile is disabled. [Fast compile](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#ofast-compile-level-ofc) | Bare `-Ofc` is accepted before another option. The dry run passes `--Ofast-compile=0` to `ptxas`. Omitting the option omits that argument. |
| nvcc 13.5.37 | Help lists `use-lcs` and `gen-lcs` for `-hls` and omits the default mode. The manual gives `use-lcs` as the default. [Host linker script](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#host-linker-script-use-lcs-gen-lcs-hls) | Bare `-hls` is accepted before another option. It emits the same linker-script generation step as `-hls use-lcs`. |
| ptxas 13.5.37 | The options-file entry describes inclusion and leaves quoting unspecified. [Options files](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#ptxas-options-options-file) | Single quotes are filename bytes. Within double quotes, an escaped double quote is discarded and `\f` becomes `f`. |
| ptxas 12.6.85 and 13.5.37 | The PTX ISA specifies zero for omitted `.file` timestamp and size fields. [PTX ISA 8.5](https://docs.nvidia.com/cuda/archive/12.6.2/parallel-thread-execution/index.html#debugging-directives-file) | With `-lineinfo`, 12.6.85 uses the referenced source file's mtime and size in the emitted line table. 13.5.37 emits zero for both fields in the same probe. |

## Reproduce with an unwrapped toolkit

Use a scratch directory and put the vendor executables on PATH. For the
NVCC dry runs, use a host compiler supported by the toolkit.

~~~sh
cat > input.ptx <<'EOF'
.version 8.0
.target sm_80
.address_size 64
.file 1 "source.cu"
.visible .entry t() { .loc 1 1 0 ret; }
EOF
printf '%s\n' '__global__ void t() {}' > source.cu

ptxas -arch=sm_80 -O input.ptx -o short.cubin
ptxas -arch=sm_80 -O0 input.ptx -o attached.cubin
ptxas -arch=sm_80 --opt-level 0 input.ptx -o long.cubin
ptxas -arch=sm_80 -O 0 input.ptx -o separate.cubin  # Fails opening 0
ptxas --help | grep -F -- 'nv-host'  # No match
ptxas --nv-host  # Missing operand on 13.5.37
ptxas -nv-host

cp input.ptx ab.ptx
cp input.ptx dirfile.ptx
printf '%s\n' "-arch=sm_80 -o single.cubin 'input.ptx'" > single.optf
printf '%s\n' '-arch=sm_80 -o quote.cubin "a\"b.ptx"' > quote.optf
printf '%s\n' '-arch=sm_80 -o slash.cubin "dir\file.ptx"' > slash.optf
ptxas -optf single.optf  # Fails opening 'input.ptx', including the quotes
ptxas -optf quote.optf
ptxas -optf slash.optf

for seconds in 1000 2000; do
  touch -d "@$seconds" source.cu
  ptxas -arch=sm_80 -lineinfo input.ptx -o "$seconds.cubin"
  readelf --debug-dump=rawline "$seconds.cubin" | grep -F source.cu
done

nvcc --dryrun -arch=sm_80 -x cu source.cu
nvcc --dryrun -arch=sm_80 -Ofc -x cu source.cu
nvcc --dryrun -arch=sm_80 -hls -x cu source.cu
nvcc --dryrun -arch=sm_80 -hls use-lcs -x cu source.cu
~~~
