# CUDA tool wrapper library

This header-only C++23 library provides the Linux process and file handling used by CUDA wrappers. A wrapper can
give the vendor tool reproducible inputs or edit metadata in an artifact it produces. CUDA packages opt in per
executable at build time by installing an adapter at the executable's public path. There is no runtime registry.
The library is compiled into each adapter.

## Invocation semantics

- The wrapper resolves its own installed path through `/proc/self/exe` and launches the vendor executable
  `.<tool>-wrapped` beside it. `nvcc` uses its installed public path as `argv[0]` to find its toolkit profile.
- When an adapter needs to wait, the vendor's error exit or termination signal takes precedence over artifact edits.
  In a background build the wrapper forwards catchable cancellation signals to the vendor's process group.
  In the foreground, terminal signals reach the shared group directly. The wrapper forwards signals sent to its
  own PID to the immediate tool. After `SIGKILL`, a later `nvcc` invocation can recover its scratch directory
  once any subprocesses holding the lock exit.
- Output adapters honor the last explicit `-o` or `--output-file`, including options files. Binary
  metadata edits run after the vendor succeeds and preserve the artifact's size. Informational calls such as
  `--version` skip editing.
  Callers must keep options files stable for the duration of a call and give independent builds separate outputs.

## Adding a wrapper

1. Reproduce the output difference or unintended Nix store reference with the vendor executable. Find which tool
   writes the value and which versions are affected. If a supported flag can control the value, prefer that flag.
2. Write a C++ adapter that inspects the arguments and applies the tool's reproducibility rules. Use
   [`nvcc-wrapper.cpp`](../packages/cuda_nvcc/nvcc-wrapper.cpp) for an example of supplying flags and
   [`nvlink-wrapper.cpp`](../packages/cuda_nvcc/nvlink-wrapper.cpp) for an example of editing a generated file.
3. Build the adapter with [`mk-tool-wrapper.nix`](./mk-tool-wrapper.nix), passing its derivation name, source under
   `cuda-modules`, description, and any required compiler flags. See
   [`nvcc-wrapper.nix`](../packages/cuda_nvcc/nvcc-wrapper.nix).
4. In the package's install phase, move the original executable to `.<tool>-wrapped` in the same directory and
   copy the adapter to the original path. `cudaWrapper::Tool("<tool>")` locates the vendor executable next to the
   installed adapter, including when the adapter is reached through a symlink. Use the path the calling program
   actually resolves. For example, `nvcc` looks up `nvlink` next to itself. See
   [the installation in `cuda_nvcc/package.nix`](../packages/cuda_nvcc/package.nix).
5. Test the installed entry point with the real vendor executable and inspect the resulting metadata or compare
   repeated outputs. Test that explicit caller options and the vendor tool's failure status are preserved. See
   [`cuda_nvcc/tests.nix`](../packages/cuda_nvcc/tests.nix).

## Library interfaces

- [`arguments.hpp`](./include/arguments.hpp) scans options and their operands and locates a generated output.
  The adapter supplies the tool's option table.
- [`process.hpp`](./include/process.hpp) provides `Tool::exec` when the adapter can hand off to the vendor executable and
  `Tool::run` when it needs to wait, clean up, or edit the result. `run` forwards signals and returns a wait status.
  Call `exitStatus` after cleanup to propagate the exit code or termination signal. `Tool::editOutput`
  handles the success check and generated-file lifecycle for output adapters.
- [`scratch.hpp`](./include/scratch.hpp) provides stable identifiers and locked scratch directories for tools whose
  intermediate filenames can appear in outputs. Pass the directory descriptor to `Tool::run` so the compiler
  can hold the lock across `exec`.
- [`files.hpp`](./include/files.hpp) provides bounded access to artifact bytes. `GeneratedFile` captures
  an output's file identity before the tool runs and verifies it before editing. `MemoryBuffer` provides the
  same byte-access interface for artifacts returned by APIs.
- [`elf.hpp`](./include/elf.hpp) edits named sections of 64-bit little-endian ELF files in place.
  [`nix-store.hpp`](./include/nix-store.hpp) replaces hashes at fixed width. Use these on metadata that has been verified
  to carry incidental references. For example, `nvlink` applies the hash transform to `.note.nv.tkinfo`.

## CUDA tools

| Executable | Behavior |
| --- | --- |
| `nvcc` | Selects the packaged host compiler, stabilizes intermediate filenames where safe, and adds a CUDA 12.9+ seed for eligible single-source compilations. [Compiler wrapper](../packages/cuda_nvcc/README.md#nvcc-wrapper) |
| `nvlink` | Clears Nix store hashes in the cubin's toolkit-info note, including inherited notes. [Linker wrapper](../packages/cuda_nvcc/README.md#nvlink-wrapper) |
