# CUDA tool wrapper library

This Rust library provides the Linux process and file handling used by CUDA wrappers. A wrapper can
give the vendor tool reproducible inputs or edit metadata in an artifact it produces. CUDA packages opt in per
executable at build time by installing an adapter at the executable's public path. There is no runtime registry.
Each adapter compiles against the pinned source from Nixpkgs' [`tool-wrapper` package](../../../by-name/to/tool-wrapper/package.nix)
and statically links it with musl. The vendor executable runs with
its own runtime. The [Cargo guide](./README.rust.md) describes using the
same artifact functions in an application, dependency choices, and a runnable JIT example.

## Invocation semantics

- The wrapper resolves its own installed path through `/proc/self/exe` and launches the vendor executable
  `.<tool>-wrapped` beside it. `nvcc` uses its installed public path as `argv[0]` to find its toolkit profile.
  The vendor inherits closed standard descriptors and the caller's `SIGCHLD` and `SIGPIPE` dispositions.
- Input adapters preserve argument order and explicit settings within each tool's policy. For `ptxas` and
  `fatbinary`, a changed options file is replayed at the same position through an anonymous file descriptor.
  Nested files retain their boundaries, and large operands stay in files. When normalization is active,
  unreadable options files and unrepresentable replacements produce an error.
- When an adapter needs to wait, the vendor's error exit or termination signal takes precedence over artifact edits.
  Each shim supervises its direct child. The vendor can start threads and subprocesses, and a build system can launch
  multiple shims in parallel.
  In a background build the wrapper forwards catchable cancellation signals to the vendor's process group.
  In the foreground, terminal signals reach the shared group directly. The wrapper forwards signals sent to its
  own PID to the immediate tool. A signal sent explicitly to the shared foreground group can reach the tool twice.
  After `SIGKILL`, a later `nvcc` invocation can recover its scratch directory
  once any subprocesses holding the lock exit.
- Output adapters honor the last explicit `-o` or `--output-file`, including options files. The standalone PTX
  adapter also recognizes `nvcc`'s default output names. Edits run after the vendor succeeds, and informational calls
  such as `--version` skip editing. Binary metadata edits are fixed-width. Standalone PTX can change size.
  Callers must keep options files stable for the duration of a call and give independent builds separate outputs.

## Adding a wrapper

1. Reproduce the output difference or unintended Nix store reference with the vendor executable. Find which tool
   writes the value and which versions are affected. If a supported flag can control the value, prefer that flag.
2. Add a Rust adapter under [`rust/src/bin`](./rust/src/bin) that inspects the arguments and applies
   the tool's reproducibility rules. Declare the binary in [`Cargo.toml`](./rust/Cargo.toml)
   with `required-features = ["wrapper"]` and use `wrap_tool!(Some("tool"), adapter)` as the CLI entry
   point. Use `None` to derive the vendor name from the installed adapter's filename.
   See the [`nvlink` adapter](./rust/src/adapters/nvlink.rs) for an example of editing a generated file.
3. Choose an output of [`cudaToolWrapper`](../packages/cudaToolWrapper.nix) for a standalone adapter,
   or register the tool with the [shared runner](./rust/src/bin/cuda-wrapper.rs) and pass any toolkit-specific
   settings as launcher arguments.
4. Use `installAdjacentWrapper` to install the adapter or its launcher. The helper moves the vendor
   executable to `.<tool>-wrapped`. See the [`cuda_nvcc` executable inventory](../packages/cuda_nvcc/package.nix).
5. Test the installed entry point with the real vendor executable and inspect the resulting metadata or compare
   repeated outputs. Test that explicit caller options and the vendor tool's failure status are preserved. See
   [`cuda_nvcc/tests.nix`](../packages/cuda_nvcc/tests.nix).

## Checking argument syntax

The adapters preserve argument spelling and group operands where a rewrite needs
their role. At packaging time the [operand probe](../packages/cuda_nvcc/option-operands.py)
takes long names and aliases from each binary's help and checks each spelling
for a required separate argument. The wrapper consults that table first. If a
spelling is absent and followed by a separate word, the wrapper asks the vendor
parser using synthetic arguments. It reuses the answer within that invocation
and reports an error for unrecognized diagnostic formats. The
[vendor documentation tracker](./vendor-tool-issues.md) records the observed
help and parser differences.

## Library interfaces

- [`arguments`](./rust/src/arguments.rs) inspects options, locates outputs, and replaces selected operands.
  It preserves the spelling of unedited arguments. `ptxas` and `fatbinary` discard escaped double quotes in
  options files. Replacements requiring literal double quotes in those files produce an error.
- [`process`](https://github.com/ConnorBaker/tool-wrapper/blob/7366fc4dc4b175d99cff84341bca7af4defb6387/src/process.rs) provides `Tool::exec` for direct handoff and `Tool::run` for waiting,
  forwarding signals, and propagating the tool's exit status. `Tool::edit_output` edits artifacts after success.
  `wrap_tool!(None, adapter)` selects the vendor tool using the installed filename.
- [`scratch`](https://github.com/ConnorBaker/tool-wrapper/blob/7366fc4dc4b175d99cff84341bca7af4defb6387/src/scratch.rs) provides stable identifiers and locked scratch directories. Pass the
  directory lease to `Tool::run` so the compiler can hold the lock across `exec`.
- [`files`](https://github.com/ConnorBaker/tool-wrapper/blob/7366fc4dc4b175d99cff84341bca7af4defb6387/src/files.rs) provides anonymous inputs and bounded access to artifact bytes. `GeneratedFile`
  checks that the vendor rewrote the intended file. `Artifact::Bytes` gives in-process compiler and linker
  results the same interface.
- [`artifact`](./rust/src/artifact.rs) edits named ELF64 sections and normalizes regular `ar` member timestamps and ownership
  while preserving offsets. `nvlink` blanks candidate store hashes in `.note.nv.tkinfo` and rejects non-ELF
  outputs with candidates using a bounded, read-only scan.
- [`path_prefix_map`](https://github.com/ConnorBaker/tool-wrapper/blob/7366fc4dc4b175d99cff84341bca7af4defb6387/src/path_prefix_map.rs) parses and applies `BUILD_PATH_PREFIX_MAP`.
- [`ptx`](./rust/src/ptx.rs) rewrites source records in PTX.

## CUDA tools

| Executable | Behavior |
| --- | --- |
| `nvcc` | Selects the packaged host compiler, stabilizes intermediate filenames where safe, adds a CUDA 12.9+ seed for eligible single-source compilations, and remaps textual source paths in standalone PTX when requested. [Compiler wrapper](../packages/cuda_nvcc/README.md#nvcc-wrapper) |
| `nvlink` | Clears Nix store hashes in the cubin's toolkit-info note, including inherited notes. [Linker wrapper](../packages/cuda_nvcc/README.md#nvlink-wrapper) |
| `ptxas` | Supplies stable source timestamps for CUDA 12.6 through 13.3 and remaps PTX `.file` paths when requested. [Assembler wrapper](../packages/cuda_nvcc/README.md#ptxas-and-fatbinary-wrappers) |
| `fatbinary` | Remaps matching image identifiers and the source paths in embedded PTX when requested. [Fat binary wrapper](../packages/cuda_nvcc/README.md#ptxas-and-fatbinary-wrappers) |
| `nvprune` | Zeros archive member and symbol table timestamps, user IDs, and group IDs. Standalone object outputs retain their contents. [Package](../packages/cuda_nvprune/package.nix) |
| `tileiras` | The existing package wrapper defaults `CUDA_ROOT` for toolkit discovery. When it resolves `ptxas` through `cuda_nvcc`, the assembler remaps source paths for the Tile IR compilation. [Package](../packages/cuda_tileiras.nix) |
| `cudafe++`, `cicc` | Share an adapter that remaps the original source path used to derive internal symbol names when `BUILD_PATH_PREFIX_MAP` is set. For `cicc`, a mapped alias of the current directory also stabilizes debug and LTO metadata. [Working directory mapping](../packages/cuda_nvcc/README.md#nvcc-wrapper) |
| `bin2c` | Embeds its input bytes in generated C. Frontend, assembler, and fat binary adapters remap paths before this stage. |
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

See the [JIT guide](./README.jit.md) for NVRTC, nvJitLink, and applying the artifact helpers to bytes returned by a library.
