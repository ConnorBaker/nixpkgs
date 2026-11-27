# cuda_nvcc

The package installs static adapters beside the vendor programs. Its executable inventory is checked at build time.
See the [CUDA wrapper guide](../../wrapper/README.md) for the installer and adapter APIs.

## nvcc wrapper

The wrapper supplies a compatible host compiler and uses locked intermediate directories to keep
PID-based filenames out of artifacts. CUDA 12.9 and newer also get an automatic seed for eligible
single-source compilations. Explicit seeds and intermediate-file options take precedence.

The frontend adapters honor `BUILD_PATH_PREFIX_MAP`. Full device debug (`-G`) and standalone LTO IR also
record the working directory. For byte reproducibility, map that directory to a stable alias that resolves
to it, and use relative source paths.

```sh
BUILD_PATH_PREFIX_MAP="/proc/self/cwd=$(pwd -P)" nvcc -G -cubin kernel.cu
```

## nvlink wrapper

`nvlink` records its arguments, including library search paths, in cubin toolkit notes. The wrapper blanks
Nix store hashes in those notes while preserving the layout of the cubin. Use `cuobjdump -elf` to inspect
the recorded arguments.

## ptxas and fatbinary wrappers

`ptxas`, `fatbinary`, and `nvcc --ptx` remap textual source paths with `BUILD_PATH_PREFIX_MAP`.
On CUDA releases before 13.4, the `ptxas` adapter also prevents line tables from inheriting source file
timestamps from the filesystem.

## Testing

Run `nix-build -A cudaPackages.cuda_nvcc.tests.<name>`. The [test definitions](./tests.nix) cover compiler
reproducibility, toolkit notes, path mapping, and process handling. The `gpuCheck` attribute runs on a GPU.
