# CUDA adapters and artifact helpers

The [Cargo crate](./rust) exposes PTX normalization, artifact editing, and
prefix maps without requiring the CUDA Toolkit. The adapters use the generic
[`tool-wrapper` crate](https://github.com/ConnorBaker/tool-wrapper) for
process invocation, response-file replay, and format-level artifact editing.
Nixpkgs owns the NVIDIA argument and artifact policies.

See the [adapter and launcher guide](./README.adapters.md) and the
[in-process reproducibility guide](./README.jit.md).

## Building and checking

From the Nixpkgs root, `nix-build -A cudaPackages.cudaToolWrapper` builds the
static adapters and runs unit tests, rustfmt, and Clippy on native Linux.

Nix builds the adapters against the source pinned by `pkgs.tool-wrapper`.
For a direct Cargo build, run this from [`rust/`](./rust) to link that same source
into the checkout.

```sh
nix-build ../../../../.. -A tool-wrapper.src -o tool-wrapper
cargo test --locked --all-features --all-targets
```

The library can then be used from another Unix application as a path dependency.

```toml
[dependencies]
cuda-tool-wrapper = { path = "/checkout/nixpkgs/pkgs/development/cuda-modules/wrapper/rust" }
```

- `PathPrefixMap::parse` and `ptx::normalize_source_info` accept byte strings. The PTX
  function remaps eligible `.file` entries and can write stable line-table metadata
  before assembly or linking. It returns `None` if it makes no edits.
- `artifact::edit_elf_sections` accepts a mutable byte buffer or an open file through
  `artifact::Artifact`. It updates all file-backed sections with the requested byte name
  in ELF64 little-endian objects and preserves file offsets and section lengths.
  Callers choose the scope of editing, such as blanking hashes inside `.note.nv.tkinfo`.
  File edits use positioned I/O and leave the caller's seek offset alone.
  A standalone caller that needs all-or-nothing writes should edit a copy.
- `artifact::normalize_archive_metadata` zeros date, UID, and GID fields in regular
  `ar` archives and leaves member payloads, padding, and symbol offsets where they were.
## Linux executable wrappers

Enable the `wrapper` feature for argument and response-file handling, scratch
directories, and process invocation.

```toml
[dependencies]
cuda-tool-wrapper = { path = "/checkout/nixpkgs/pkgs/development/cuda-modules/wrapper/rust", features = ["wrapper"] }
```

Use `wrap_tool!` once in the CLI binary to capture the caller's stdio and signal
state before Rust initializes its runtime. The adapter can either replace itself
with the vendor executable or supervise it and edit its output. The
[wrapper README](./README.md) describes the process protocol. Nix enables the
feature when it builds the six bundled adapters as static musl executables.

The adapter crate requires Rust 1.98 for `slice::subslice_range`. The
`tool-wrapper` package runs the generic library tests separately.
[Rust slice API](https://doc.rust-lang.org/stable/std/primitive.slice.html#method.subslice_range)

## Dependency evaluation

| Need | Crates and findings |
| --- | --- |
| Find mutable ELF sections | The prototype uses `object` 0.41 with `elf`, `read_core`, `std`, and `unaligned`. Its low-level section parser handles extended numbering, names, and file ranges. `ReadCache` reads the metadata it needs from a file. The wrapper owns positioned I/O, validation of the selected ranges, and the fixed-size writes. [object ELF reader](https://docs.rs/object/latest/object/read/elf/index.html), [ReadCache](https://docs.rs/object/latest/object/read/struct.ReadCache.html) |
| Other ELF and debug readers | `elf::ElfStream` is a viable smaller API for an ELF-only consumer. It opens a seekable input and reads both section and program headers. `goblin`'s convenience ELF parser expects a byte slice, and a mapping through `memmap2` requires the file to remain valid for the lifetime of the map. `gimli` can read or rebuild standard DWARF if a future feature needs to interpret it. Arbitrary DWARF path changes can change section sizes and references, so that requires repacking the artifact and testing the resulting CUDA metadata. [elf](https://docs.rs/elf/latest/elf/struct.ElfStream.html), [goblin](https://docs.rs/goblin/latest/goblin/elf/struct.Elf.html), [memmap2](https://docs.rs/memmap2/latest/memmap2/struct.Mmap.html), [gimli](https://docs.rs/gimli/latest/gimli/) |
| Raw byte text | `bstr::ByteSlice` provides byte-preserving delimiter searches and splits. The wrapper uses `memchr` directly for delimiter searches. The crate is already part of the `object` dependency graph. `regex::bytes` and parser combinators become more useful with larger grammars. The few CUDA-specific PTX token and hash rules remain short. [bstr](https://docs.rs/bstr/latest/bstr/trait.ByteSlice.html), [memchr](https://docs.rs/memchr/latest/memchr/), [regex bytes](https://docs.rs/regex/latest/regex/bytes/), [winnow](https://docs.rs/winnow/latest/winnow/) |
| Arguments and response files | `shlex::bytes` handles shell quoting and comments, which would change NVIDIA's handling of literal single quotes, `#`, and escaped double quotes. `lexopt` and `clap` help implement a CLI whose option grammar we own. These shims must replay the vendor's original argument tokens, including unknown and single-dash long options, and retain the argument positions and boundaries of nested option files. The current byte parser implements those rules directly. [shlex source](https://github.com/comex/rust-shlex), [lexopt](https://docs.rs/lexopt/latest/lexopt/), [clap](https://docs.rs/clap/latest/clap/) |
| Archive headers | `ar::Archive::next_entry` and `object::ArchiveFile::members` iterate regular members. GNU symbol tables and the long-name table get special treatment. We need to inspect the raw headers, including the symbol table header, and leave the archive layout and offsets intact. Keep the fixed-width metadata editor. [ar reader](https://docs.rs/ar/latest/ar/struct.Archive.html), [object archive reader](https://docs.rs/object/latest/object/read/archive/struct.ArchiveFile.html) |
| Linux primitives | `rustix` returns owned anonymous descriptors and typed PIDs and exposes parent-death and foreground-group operations. The optional wrapper code uses its `fs`, `process`, and `termios` features. The standard library already supplies locking, positioned file I/O, and launching or replacing a process. `tempfile` handles temporary paths or anonymous files, while the CUDA scratch policy needs a repeatable path, ownership checks, and a lock inherited by vendor subprocesses. [rustix FS](https://docs.rs/rustix/latest/rustix/fs/fn.memfd_create.html), [rustix process](https://docs.rs/rustix/latest/rustix/process/), [Rust File API](https://doc.rust-lang.org/stable/std/fs/struct.File.html), [tempfile](https://docs.rs/tempfile/latest/tempfile/) |
| Process supervision | `process-wrap` can create and manage a child process group. `signal-hook` manages signal handlers. `nix::sys::signalfd` is a possible event-loop primitive and exposes sender information. We still need the caller's original descriptor and signal state, the foreground terminal delivery rule, the scratch lease across exec, and propagation of the original child status or terminating signal. The prototype keeps this policy and the relevant `libc` calls. [process-wrap](https://docs.rs/process-wrap/latest/process_wrap/), [signal-hook](https://docs.rs/signal-hook/latest/signal_hook/), [nix SignalFd](https://docs.rs/nix/latest/nix/sys/signalfd/struct.SignalFd.html) |
| Prefix maps | Apply the reproducible-builds escaping and last-match precedence at the CUDA call site. Rust's own remapping flags affect rustc-generated paths. The crate applies the map to CUDA path bytes and also requires a path-component match. [BUILD_PATH_PREFIX_MAP specification](https://reproducible-builds.org/specs/build-path-prefix-map/), [rustc remapping](https://doc.rust-lang.org/rustc/remap-source-paths.html) |

## In-process CUDA example

The [example crate](./examples/jit) compiles a kernel via `cudarc::nvrtc`, remaps
the returned PTX, and passes the resulting bytes to `baracuda_nvjitlink::Linker`.
It loads NVIDIA shared libraries dynamically and uses no GPU. From a temporary
directory, run the following with `wrapper` set to the absolute path to this directory
and the CUDA libraries on the dynamic loader's search path.

```sh
CUDA_CACHE_DISABLE=1 cargo run --locked --manifest-path "$wrapper/examples/jit/Cargo.toml"
readelf --debug-dump=rawline kernel.cubin
```

The example writes `kernel.ptx` and `kernel.cubin`. With CUDA 12.9.2 and 13.4.3
on aarch64 Linux, both artifacts matched byte for byte across two working directories
for each version. The cubin's line table contained `/virtual` and `kernel.cu` on both.
The application supplies the virtual filename, random seed, target, and input order.
This example exercises line information on PTX and cubin. Full debug and raw LTO
have additional constraints described in the [wrapper README](./README.md#in-process-compilation-and-linking).
[NVRTC API](https://docs.nvidia.com/cuda/nvrtc/index.html), [nvJitLink API](https://docs.nvidia.com/cuda/nvjitlink/index.html)

`cudarc` offers NVRTC bindings with selectable toolkit and linkage features. Its
safe convenience API handles one source string and source name. Use lower-level
NVRTC bindings when you need to pass in-memory headers or obtain other output kinds.
`baracuda-nvjitlink` offered the safe handle API used here and is an alpha dependency.
NVIDIA's `cuda-rust` tree also ships a dynamic `nvjitlink-sys` binding for its
LTO path. Baracuda and `singe-cuda` offer other NVRTC bindings. Keep CUDA bindings in the calling application. The CLI wrappers and
artifact library build without them.
[cudarc](https://docs.rs/crate/cudarc/latest/features), [Baracuda Linker](https://docs.rs/baracuda-nvjitlink/latest/baracuda_nvjitlink/struct.Linker.html),
[NVIDIA cuda-oxide](https://github.com/NVIDIA/cuda-rust/blob/main/cuda-oxide/README.md),
[Baracuda NVRTC](https://docs.rs/baracuda-nvrtc/latest/baracuda_nvrtc/), [singe-cuda](https://docs.rs/singe-cuda/latest/singe_cuda/)

## Cost and verification

The default build compiles two dependencies, `object` and `memchr`. On aarch64
Linux, the `wrapper` feature adds four, `libc`, `rustix`, `bitflags`, and
`linux-raw-sys`. Rustix replaces individual raw calls, and object reads ELF
headers and section tables.

The table compares installed CUDA 13.5 aarch64 musl adapters after Nix strips
debug information. The package enables ThinLTO for the release build.

| Adapter | libc-only (bytes) | First prototype (bytes) | Feature split (bytes) | With ThinLTO (bytes) |
| --- | ---: | ---: | ---: | ---: |
| nvcc | 875288 | 944392 | 944232 | 858472 |
| nvlink | 778672 | 858832 | 855168 | 770384 |
| ptxas | 766960 | 771640 | 770768 | 751920 |
| fatbinary | 766696 | 771360 | 770480 | 751696 |
| nvprune | 778208 | 848056 | 778784 | 759520 |
| cudafe++ / cicc (one adapter) | 768400 | 772936 | 769120 | 750528 |

These measurements used static executables. The `nvcc` adapter retained its
configured host compiler reference. The package tests exercise the shipped
compiler, including retrying a compilation after its wrapper is killed while
the real host preprocessor holds the scratch directory open.

On a synthetic ELF with 70,000 extra section headers, `strace` counted 70,016
positioned reads in the original `nvlink` wrapper and six in the prototype. The
edited files matched byte for byte. The prototype caches the entire section
table, so peak memory now grows with the number of sections. Both implementations
also load the string table and the contents of the section being edited.
