# cuda_nvcc

## nvcc wrapper

[`nvcc-wrapper.rs`](../../wrapper/rust/src/bin/nvcc-wrapper.rs) is statically linked with musl and installed as
`bin/nvcc` beside NVIDIA's `bin/.nvcc-wrapped`. It adds the selected host compiler to `PATH` and supplies flags
that make intermediate filenames and internal symbols reproducible. It uses the
[CUDA tool wrapper library](../../wrapper/README.md) to inspect options files, find the installed executable,
forward signals, and preserve the wrapped tool's exit status.

### Why

Without these options, nvcc writes a different object each time it compiles the same source file. There are two
causes.

The first cause is the names of the intermediate files. nvcc names them after its process ID, for example
`tmpxft_<pid>_<n>-<m>_<source>.cudafe1.cpp`, and the host compiler compiles the host code from them. The host compiler
stores the file name in the symbol table of the object, as the `STT_FILE` symbol. It also names the function that runs
the static initializers after the file: `_GLOBAL__sub_I_tmpxft_<pid>_...`. `strip -S` removes the `STT_FILE` symbol,
but it does not remove the name of that function.

The second cause is the names of entities with internal linkage, for example functions in an unnamed namespace. nvcc
gives every source file an identifier and puts it into these names: `_INTERNAL_<identifier>...` and
`_GLOBAL__N__<identifier>`. The names are used in the host code and in the device code. The identifier is the same in
every build if the source file defines a function or a variable that has external linkage and is not a template. If
the source file defines no such function or variable, the identifier contains the process ID. Source files that define
only templates are an example, and some of the CUDA modules of OpenCV contain such files.

nvcc has one option for each cause:

- `--keep` tells nvcc not to remove its intermediate files. nvcc then names them after the source file:
  `<source>.cudafe1.cpp`.
- `--frandom-seed` tells nvcc to derive the identifier from a seed. nvcc has this option from CUDA 12.9. nvcc also
  passes the seed to the host compiler as `-frandom-seed`. NVIDIA requires a different seed for every source file of a
  program.

These options cannot be set once for a whole build, for example through `NVCC_PREPEND_FLAGS` in `setupCudaHook`:

- `--keep` needs a directory for the intermediate files (`--keep-dir`). With one directory for the whole build, two
  source files that have the same name and are compiled at the same time would overwrite each other's files.
- The seed would be the same for every source file.

`--objdir-as-tempdir` looks like an alternative to `--keep`, because it names the intermediate files after the object
and needs no directory. It has two problems:

- It has no effect without `-c`. The object is then an intermediate file itself, and nvcc names it after the process
  ID.
- nvcc fails if the directory of the object is not writable, for example with `-o /dev/null`.

### How

The wrapper inspects the command line, `NVCC_PREPEND_FLAGS`, `NVCC_APPEND_FLAGS` and regular options files (`-optf`).
It forwards them intact and skips non-compilation invocations such as `--version`, `--dryrun`, and preprocessing.
For compilations it can add:

- `--frandom-seed` from CUDA 12.9 for a single source file. The value is derived from the working directory and source
  argument, or from the mapped source path when `BUILD_PATH_PREFIX_MAP` matches it. NVIDIA requires different seeds
  for different translation units, and one invocation can take only one seed.
- `--keep --keep-dir=$TMPDIR/nvcc-keep-<id>` (using `/tmp` if `TMPDIR` is unset). The directory name hashes the
  working directory and effective arguments, since the path can appear in debug information. Identical invocations
  serialize access to this directory. After the compiler exits, the wrapper removes the directory if it can
  reacquire the lock. If the directory remains, the next invocation waits for the lock and clears the old
  intermediates.

An explicit seed suppresses the automatic seed. `--keep`, `--keep-dir`, `--save-temps`, and `--objdir-as-tempdir`
(`-objtemp`) suppress automatic intermediate-file options. CMake uses the kept intermediates to identify the
compiler. Duplicate source stems also suppress those options because nvcc can overwrite one source's intermediates
with another's. If the wrapper cannot inspect an options file, it forwards the invocation directly. If it cannot
acquire a scratch directory, it can still supply the seed.

With a scratch directory, the wrapper waits for nvcc and cleans up before returning its exit status or terminating
with the same signal. For other invocations it directly executes nvcc. The real compiler sees the absolute public
`nvcc` path so toolkit discovery works through symlinks and CMake recognizes its version output.

CUDA before 12.9 can still put PIDs in internal symbol names. The same limitation can affect compilations of
multiple source files in one invocation. With `BUILD_PATH_PREFIX_MAP`, the frontend adapters remap the
original source path that `cudafe++` and `cicc` use to derive another part of the internal symbol name. This makes
ordinary and relocatable objects and line-info PTX reproducible across mapped build roots in the test below.
Full device debug information records the working directory separately in `DW_AT_comp_dir`.
Standalone LTO IR (`-dlto -ltoir`) also differed across mapped build roots in CUDA 13.5.

### Testing

The longer test scripts and stand-in executables are in [`tests/`](./tests). The Nix definitions supply toolkit
paths and version-dependent expectations.

- `cudaPackages.cuda_nvcc.tests.nvcc-reproducible` compiles sources twice and compares the results. It also checks
  that `bin/.nvcc-wrapped` without the wrapper still writes different objects. That check fails when a CUDA release no
  longer needs the options.
- `cudaPackages.cuda_nvcc.tests.nvcc-mapped-builds` compares objects and line-info PTX built in two directories
  mapped to the same source prefix.
- `cudaPackages.cuda_nvcc.tests.nvcc-wrapper` checks caller-supplied options and compiles through an external symlink.
- `cudaPackages.cuda_nvcc.tests.nvcc-process` uses a stand-in compiler to check concurrent invocations, signal
  forwarding, and scratch directory recovery after `SIGKILL`.

To check a package, build it twice and compare the outputs, for example with `nix-build --check`. A small test source
can be reproducible where a package is not, so check the package itself.

## nvlink wrapper

`bin/nvlink` is a wrapper around NVIDIA's nvlink, which is installed as `bin/.nvlink-wrapped`. The wrapper is built
from [`nvlink-wrapper.rs`](../../wrapper/rust/src/bin/nvlink-wrapper.rs) by [`nvlink-wrapper.nix`](./nvlink-wrapper.nix)
(`passthru.nvlinkWrapper`). The recipe links the wrapper statically with musl and the package copies it into `cuda_nvcc`.

### Why

nvlink records its command line in a note (`.note.nv.tkinfo`) in each cubin it writes, which nvcc embeds in the
`.nv_fatbin` section of the binary or object it links. The command line includes the library search paths (`-L`),
both those from `nvcc.profile` and those passed by the build, and with link-time optimization the NVVM directory
(`-nvvmpath`). Without the wrapper, these paths in the Nix store make `cuda_nvcc` and the build's dependencies runtime
dependencies of everything linked with nvcc, whether through a whole-program link, a link of relocatable device code,
or a device-link object (`nvcc -dlink`) in a static library, and whether the result is linked statically or
dynamically. (Nix doesn't find references in fatbins compressed with `-Xfatbin -compress-all`, but the paths are still
there.)

`cuobjdump -elf` shows the note (abridged):

```
.section .note.nv.tkinfo
    Tool Name: nvlink
    Tool Version: Cuda compilation tools, release 13.4, V13.4.92
    Tool Command Line Arguments: -arch sm_121a -m 64 -l cudadevrt -L /nix/store/...-cuda_cudart-13.4.92/lib,/nix/store/...-cuda_nvcc-13.4.92/bin/..//lib/stubs,... -cpu-arch AARCH64
```

nvlink writes the note from CUDA 12.8 for some architectures (e.g. `sm_100`, `sm_120`, and `sm_121a`, but not `sm_89`
or `sm_90`), and from CUDA 13 for all of them. CUDA 13's nvlink also keeps the notes of the cubins (`*.cubin`) it
links; CUDA 12's drops them. Neither nvlink nor nvcc has an option to omit the note or the arguments it records.

The alternatives don't work:

- Setting `LIBRARY_PATH` in `nvcc.profile` keeps nvcc's own directories out of the note, as nvlink searches it without
  recording it, but not the `-L` passed by builds; and link-time optimization requires `-nvvmpath`.
- Removing references after the build (e.g. with `remove-references-to`) has to be done by every package, and removes
  legitimate references to the same store paths.
- `patchelf` and `objcopy` work with whole sections; the note is inside `.nv_fatbin`, a container which
  only nvcc's tools write.
- `makeBinaryWrapper` can neither rewrite arguments nor run anything after the program it wraps.

### How

The wrapper runs `.nvlink-wrapped` from its own directory (found through `/proc/self/exe`, so also when the wrapper
is run through a symbolic link, e.g. from `cudatoolkit`) with the same arguments (including `argv[0]`, whose basename
nvlink records as the tool name) and environment. If nvlink succeeds, the wrapper overwrites with `e`s, as
`remove-references-to` does, each hash of a path in the Nix store (32 characters of Nix's base-32 alphabet, which lacks
`e`) in the `.note.nv.tkinfo` sections of its output. Nix finds references by these hashes, whatever the spelling of
the path. The wrapper reads only the ELF headers it needs and those sections, and writes back only the sections which
change, so the output's size and layout are unchanged: only the recorded command lines change, e.g. to
`-L /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-cuda_nvcc-13.4.92/...`.

The wrapper finds the last explicit `-o` or `--output-file`, including in options files (`-optf`), which nvcc uses
for long command lines. It skips other options' operands when searching for the output. Help and version calls
run without artifact edits.

The wrapper handles `SIGHUP`, `SIGINT`, `SIGQUIT`, `SIGTERM`, `SIGUSR1`, and `SIGUSR2` while it waits for nvlink.

- In the foreground of a terminal, nvlink stays in the wrapper's process group, so signals from the terminal (e.g.
  Ctrl-C) reach it directly, and the wrapper doesn't forward them.
- Otherwise, as in a build, nvlink runs in a process group of its own. The wrapper forwards signals it receives
  to nvlink's group.

nvlink is killed if the wrapper dies. If nvlink fails, the wrapper exits with its status, or is killed by the same
signal, and leaves the output as nvlink left it.

Rather than let a reference through, the wrapper fails with an error starting with `nvlink wrapper: error:`, removing
the output if nvlink wrote it, when:

- it can't parse the arguments naming the output (e.g. an options file which isn't a regular file, which nvlink would
  then find empty, as the wrapper reads options files first), before nvlink runs;
- the output exists and isn't a regular file (e.g. `/dev/stdout` when it's a pipe), which the wrapper couldn't read
  back, before nvlink runs;
- nvlink didn't write the output the wrapper found, e.g. because they disagree on the arguments;
- the output is an ELF file which isn't 64-bit and little-endian (as every CUDA ELF file is), or is malformed; or
- the output isn't an ELF file (e.g. a host linker script, from `-ghls`), but refers to the Nix store.

The wrapper is found wherever nvcc runs (nvcc looks for nvlink next to itself), as well as by anything running nvlink
directly, e.g. Clang, whose `clang-nvlink-wrapper` runs nvlink from the CUDA installation for relocatable device code
(`-fgpu-rdc`) and passes Clang's own library directory, which nvlink records too. It doesn't remove references to the
Nix store from anything else, e.g. the line information of device code compiled with `-lineinfo` or `-G`.

CUDA 13.4's nvJitLink keeps the toolkit notes of the cubins it links, including the paths recorded by an unwrapped
nvlink. Its caller can use the same note transform on the returned bytes. See
[in-process compilation and linking](../../wrapper/README.md#in-process-compilation-and-linking).

Debug and line metadata carry paths independently of the toolkit note. See
[the assembler and fat binary wrappers](#ptxas-and-fatbinary-wrappers) for the paths handled at those stages.

### Testing

- `cudaPackages.cuda_nvcc.tests` links with nvcc and nvlink in the ways listed above, and with Clang (CUDA 12.8 and
  12.9, as Clang 21 can't parse CUDA 13's headers, and not on x86_64, where the Clang wrapper passes the device code a
  flag Clang rejects), and checks the notes in the results with `cuobjdump`; the results must not refer to `cuda_nvcc`
  or `cuda_cudart` (or Clang). `cuobjdump` also reads the notes of compressed fatbins (`-Xfatbin -compress-all`), in
  which Nix doesn't find references, so `nvcc-compressed` checks those. The `wrapper` test puts the installed wrapper
  next to a stand-in for nvlink ([`tests/fake-nvlink`](./tests/fake-nvlink)) to check how it runs nvlink and handles
  its output. With CUDA 12.6, nvlink writes no note, so only the `wrapper` test checks the wrapper.
- `cudaPackages.cuda_nvcc.gpuCheck` (requires a GPU) runs programs linked through the wrapper.

When the wrapper fails, run the command with `bin/.nvlink-wrapped` in place of `bin/nvlink` and inspect its output with
`cuobjdump -elf`.

### Development

Build the adapters or run the library tests from the [Rust crate](../../wrapper/rust) with
`cargo build --locked` or `cargo test --locked`. The Nix derivations supply the host compiler path and
CUDA version flags. Use the packaged tests above to check the CUDA tools and the stand-ins.

## ptxas and fatbinary wrappers

CUDA 12.6 through 13.3 record source file modification times and sizes from the filesystem in `.debug_line` when
the PTX `.file` record leaves its timestamp unspecified or sets it to zero. The `ptxas` adapter supplies a
timestamp of 1 and a size of 0 when both were omitted. With an explicit zero timestamp, including hexadecimal and
unsigned spellings, it keeps the explicit size.
A nonzero timestamp in the PTX is preserved. CUDA 13.4 and 13.5 already produce stable records for an omitted
timestamp in the regression case. [NVIDIA PTX ISA](https://docs.nvidia.com/cuda/archive/12.9.0/pdf/ptx_isa_8.8.pdf)

CUDA also copies source paths from PTX into cubin debug metadata and can store the input name in a fat binary
identifier. The adapters accept `BUILD_PATH_PREFIX_MAP` entries in `target=source` order. For example, the following
maps paths under the working directory to `/usr/src/project` in device line information and fat binary identifiers.

```sh
BUILD_PATH_PREFIX_MAP="/usr/src/project=$PWD" nvcc -arch=sm_80 -lineinfo -c "$PWD/kernel.cu" -o kernel.o
```

`ptxas` remaps paths in textual PTX `.file` directives. `fatbinary` remaps `--ident` and applies the same
PTX transform to embedded PTX images, which can be present alongside a cubin. `nvcc --ptx` applies the transform
to standalone PTX written to regular files, including default outputs and `--output-directory`. PTX written
to standard output or special files goes directly to the caller. `tileiras` uses the assembler's remapping when
it finds `ptxas` through this toolkit. [Prefix map format](https://reproducible-builds.org/specs/build-path-prefix-map/)

With full device debugging (`-G`), CUDA 13.4 also records paths in DWARF `.debug_info`, including the compilation
unit name and the working directory. That section arrives as binary data encoded in PTX directives and needs a
DWARF-aware rewrite. Host debug sections are handled by the host compiler.
[PTX Writer’s Guide](https://docs.nvidia.com/cuda/ptx-writers-guide-to-interoperability/index.html)
