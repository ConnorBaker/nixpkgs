# CUDA tool wrapper library

This Rust library provides the Linux process and file handling used by CUDA wrappers. A wrapper can
give the vendor tool reproducible inputs or edit metadata in an artifact it produces. CUDA packages opt in per
executable at build time by installing an adapter at the executable's public path. There is no runtime registry.
Nixpkgs' static Rust toolchain links the library and musl into each adapter. The vendor executable runs with
its own runtime.

## Invocation semantics

- The wrapper resolves its own installed path through `/proc/self/exe` and launches the vendor executable
  `.<tool>-wrapped` beside it. `nvcc` uses its installed public path as `argv[0]` to find its toolkit profile.
  The vendor inherits closed standard descriptors and the caller's `SIGPIPE` disposition.
- Input adapters preserve argument order and explicit settings within each tool's policy. For `ptxas` and
  `fatbinary`, a changed options file is replayed at the same position through an anonymous file descriptor.
  Nested files retain their boundaries, and large operands stay in files. If either adapter cannot inspect
  the options files, it invokes the vendor with the caller's arguments.
- When an adapter needs to wait, the vendor's error exit or termination signal takes precedence over artifact edits.
  In a background build the wrapper forwards catchable cancellation signals to the vendor's process group.
  In the foreground, terminal signals reach the shared group directly. The wrapper forwards signals sent to its
  own PID to the immediate tool. After `SIGKILL`, a later `nvcc` invocation can recover its scratch directory
  once any subprocesses holding the lock exit.
- Output adapters honor the last explicit `-o` or `--output-file`, including options files. The standalone PTX
  adapter also recognizes `nvcc`'s default output names. Edits run after the vendor succeeds, and informational calls
  such as `--version` skip editing. Binary metadata edits are fixed-width. Standalone PTX can change size.
  Callers must keep options files stable for the duration of a call and give independent builds separate outputs.

## Adding a wrapper

1. Reproduce the output difference or unintended Nix store reference with the vendor executable. Find which tool
   writes the value and which versions are affected. If a supported flag can control the value, prefer that flag.
2. Add a Rust adapter under [`rust/src/bin`](./rust/src/bin) that inspects the arguments and applies
   the tool's reproducibility rules. Use [`nvcc-wrapper.rs`](./rust/src/bin/nvcc-wrapper.rs) for an example of supplying flags and
   [`nvlink-wrapper.rs`](./rust/src/bin/nvlink-wrapper.rs) for an example of editing a generated file.
3. Build the adapter with [`mk-tool-wrapper.nix`](./mk-tool-wrapper.nix), passing the Cargo binary name, a description,
   and any required build-time environment variables. See
   [`nvcc-wrapper.nix`](../packages/cuda_nvcc/nvcc-wrapper.nix).
4. In the package's install phase, move the original executable to `.<tool>-wrapped` in the same directory and
   copy the adapter to the original path. `wrapper_main("<tool>", …)` locates the vendor executable next to the
   installed adapter, including when the adapter is reached through a symlink. Use the path the calling program
   actually resolves. For example, `nvcc` looks up `nvlink` next to itself. See
   [the installation in `cuda_nvcc/package.nix`](../packages/cuda_nvcc/package.nix).
5. Test the installed entry point with the real vendor executable and inspect the resulting metadata or compare
   repeated outputs. Test that explicit caller options and the vendor tool's failure status are preserved. See
   [`cuda_nvcc/tests.nix`](../packages/cuda_nvcc/tests.nix).

## Library interfaces

- [`arguments`](./rust/src/arguments.rs) inspects options, locates outputs, and replaces selected operands.
  It preserves Unix arguments byte for byte. With `ptxas` and `fatbinary`, options files discard escaped
  double quotes, so rewrites requiring literal double quotes in these files are skipped.
- [`process`](./rust/src/process.rs) provides `Tool::exec` for direct handoff and `Tool::run` for waiting,
  forwarding signals, and propagating the tool's exit status. `Tool::edit_output` edits artifacts after success.
- [`scratch`](./rust/src/scratch.rs) provides stable identifiers and locked scratch directories. Pass the
  directory lease to `Tool::run` so the compiler can hold the lock across `exec`.
- [`files`](./rust/src/files.rs) provides anonymous inputs and bounded access to artifact bytes. `GeneratedFile`
  checks that the vendor rewrote the intended file. `Artifact::Bytes` gives in-process compiler and linker
  results the same interface.
- [`artifact`](./rust/src/artifact.rs) edits named ELF64 sections and normalizes regular `ar` member timestamps
  while preserving offsets. Apply `blank_store_hashes` to metadata verified to carry incidental references.
  For example, `nvlink` applies it to `.note.nv.tkinfo`.
- [`ptx`](./rust/src/ptx.rs) rewrites source records in PTX and parses `BUILD_PATH_PREFIX_MAP`.

## CUDA tools

| Executable | Behavior |
| --- | --- |
| `nvcc` | Selects the packaged host compiler, stabilizes intermediate filenames where safe, adds a CUDA 12.9+ seed for eligible single-source compilations, and remaps textual source paths in standalone PTX when requested. [Compiler wrapper](../packages/cuda_nvcc/README.md#nvcc-wrapper) |
| `nvlink` | Clears Nix store hashes in the cubin's toolkit-info note, including inherited notes. [Linker wrapper](../packages/cuda_nvcc/README.md#nvlink-wrapper) |
| `ptxas` | Supplies stable source timestamps for CUDA 12.6 through 13.3 and remaps PTX `.file` paths when requested. [Assembler wrapper](../packages/cuda_nvcc/README.md#ptxas-and-fatbinary-wrappers) |
| `fatbinary` | Remaps matching image identifiers and the source paths in embedded PTX when requested. [Fat binary wrapper](../packages/cuda_nvcc/README.md#ptxas-and-fatbinary-wrappers) |
| `nvprune` | Normalizes archive member and symbol table timestamps to zero. Standalone object outputs retain their contents. [Package](../packages/cuda_nvprune/package.nix) |
| `tileiras` | The existing package wrapper defaults `CUDA_ROOT` for toolkit discovery. When it resolves `ptxas` through `cuda_nvcc`, the assembler remaps source paths for the Tile IR compilation. [Package](../packages/cuda_tileiras.nix) |
| `cudafe++`, `cicc`, `bin2c` | Internal frontend and embedding stages can carry paths from their inputs. The public tool wrappers handle PTX source directives, fat binary identifiers, and toolkit notes at the relevant output boundaries. |
| `__nvcc_device_query` | `nvcc -arch=native` uses this helper to choose code generation targets from the host's GPUs. Use explicit architectures for hardware-independent builds. |
| `cuobjdump`, `nvdisasm`, `tileirdisasm`, `cu++filt` | These inspection tools expose information from their inputs. Use them to verify fixes at the producer. |
| `ctadvisor`, CUDA-GDB, Nsight, Compute Sanitizer | These tools report compilation timings, runtime observations, or source locations for diagnostics. Their reports are distinct from compiler artifacts. |
| TensorRT `trtexec` | Known source of nondeterminism. Timing noise during engine builds can change which GPU kernels the builder selects. TensorRT's editable timing cache can pin tactic choices for a specific model, build configuration, and hardware. [NVIDIA TensorRT documentation](https://docs.nvidia.com/deeplearning/tensorrt/10.x.x/inference-library/precision-control.html#algorithm-selection-and-reproducible-builds) |

For a derivation that builds a TensorRT engine, supply its compatible cache with `--timingCacheFile`. On versions
that expose `--errorOnTimingCacheMiss`, use it to fail if the builder needs to profile an uncached tactic. This
controls tactic selection. Verify the serialized engine separately if the package requires byte-identical outputs.
[TensorRT command-line documentation](https://docs.nvidia.com/deeplearning/tensorrt/10.x.x/reference/command-line-programs.html)
and [trtexec option parser](https://github.com/NVIDIA/TensorRT/blob/release/10.13/samples/common/sampleOptions.cpp)

## In-process compilation and linking

NVRTC, nvJitLink, the PTX Compiler API, libNVVM, and nvFatbin run inside the application. The application supplies
the compilation or link options and receives the generated bytes. That is where to apply reproducibility policy
when a package installs or embeds those bytes. The executable adapters are reached only by launching their
installed paths. Rust callers can apply the artifact helpers directly to the returned bytes.

- **NVRTC.** Pass stable absolute virtual filenames to `nvrtcCreateProgram` for the primary source and any
  in-memory headers named in debug metadata. Keep the `#include` spelling consistent with the header name passed
  to NVRTC and control the paths of headers loaded from disk. Pass an explicit target to `nvrtcCompileProgram`
  and, with CUDA 12.9 or later, a `--frandom-seed` derived from a stable identifier for the translation unit.
  `normalize_source_info` can remap `.file` paths in the bytes from `nvrtcGetPTX` before the caller links or
  stores them. `BUILD_PATH_PREFIX_MAP` had an effect only when applied by the caller in these tests.
  [NVRTC API and compiler options](https://docs.nvidia.com/cuda/archive/13.4.1/nvrtc/index.html)

  In uncached tests with CUDA 12.9.2 and 13.4.3, unseeded outputs differed even in the same directory. Relative
  source and in-memory header names picked up the working directory. A stable virtual source name and fixed
  seed made the tested PTX and cubins match across directories with default options or line info. With full
  debug, `DW_AT_comp_dir` still recorded the working directory. Raw LTO IR differed across directories in all
  three modes. Its linked cubin matched with default options or line info and differed with full debug. For
  builds that need full debug or byte-identical raw LTO IR, run the compiler in a process with a stable working
  directory. Source that uses `__DATE__` or `__TIME__` also needs a stable value supplied by the application.
  Both versions used the wall clock for those macros even with `SOURCE_DATE_EPOCH` set.
- **nvJitLink.** Set an explicit target and submit reproducible inputs in a fixed order via `nvJitLinkAddData`
  or `nvJitLinkAddFile`. The linked cubins matched when the input bytes were held fixed and the caller's
  directory and input labels or filenames varied. Paths already embedded in the inputs carried through.
  On CUDA 12.9.2, changing the size and mtime of a file named in a PTX `.file` directive also changed the
  linked cubin's line table. Passing `true` for `normalize_source_info`'s `normalize_timestamp` parameter
  made that case repeatable before linking. CUDA 13.4.3 emitted zero for both fields in the same test.
  [nvJitLink API](https://docs.nvidia.com/cuda/archive/13.4.1/nvjitlink/index.html)

  CUDA 13.4.3 also carried input cubins' `.note.nv.tkinfo` into the linked cubin. When the caller packages the
  result, it can apply the same fixed-width note edit as `nvlink` after `nvJitLinkGetLinkedCubin` succeeds. The
  edit targets the toolkit note. Source and debug paths require the corresponding input-side handling.

```rust
use cuda_tool_wrapper::artifact::{blank_store_hashes, edit_elf_sections};
use cuda_tool_wrapper::files::Artifact;
use std::io;

fn clean_cubin(cubin: &mut [u8]) -> io::Result<bool> {
    edit_elf_sections(&mut Artifact::Bytes(cubin), b".note.nv.tkinfo", blank_store_hashes)
}
```
