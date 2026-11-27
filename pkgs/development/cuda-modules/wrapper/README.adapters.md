# CUDA adapters

The [`cuda-tool-wrapper` crate](./rust) contains the NVIDIA-specific
response-file parser, PTX source metadata editor, and executable adapters.
Link the [pinned library source](./README.rust.md#building-with-cargo) into
[`rust/`](./rust), then run this there to build the adapters and shared runner.

```sh
cargo build --locked --release --features wrapper --bins
```

Install each adapter using the [adjacent-executable layout](./README.md).
Keep the staged toolkit's directory structure intact so `nvcc` and the other
tools can locate their own executables and libraries. `nvcc` uses its
installed public path as `argv[0]` to find its toolkit profile.

The `nvcc` and `ptxas` launchers share the `cuda-wrapper` binary.
The [package](../packages/cuda_nvcc/package.nix) installs them using
[`installCudaLauncher`](../packages/cuda_nvcc/install-launcher.sh) and generates
each operand table after fixing the vendor binaries' interpreters. The launcher
passes the table, tool-specific settings, and the installed path as arguments.
The runner uses the basename to select the adapter and finds the vendor
executable beside the launcher, including when invoked through a symlink.

| Adapter | Public executable | Behavior |
| --- | --- | --- |
| `cuda-wrapper` | `nvcc` | Selects the configured host compiler, stabilizes intermediate names and seeds where applicable, and remaps source paths in standalone PTX. |
| `nvlink-wrapper` | `nvlink` | Clears Nix store hashes in the cubin's toolkit-info note, including inherited notes. |
| `cuda-wrapper` | `ptxas` | Remaps PTX source paths and can supply stable source metadata. |
| `fatbinary-wrapper` | `fatbinary` | Remaps matching image identifiers and source paths in embedded PTX. |
| `nvprune-wrapper` | `nvprune` | Zeros dates, UIDs, and GIDs in archive member and symbol table headers. |
| `cuda-frontend-wrapper` | `cudafe++`, `cicc` | Remaps source paths used for internal names. For `cicc`, it can also stabilize the working directory recorded in debug and LTO metadata. |

Adapters read `BUILD_PATH_PREFIX_MAP` at invocation time.

Rewritten options files are replayed at their original position through
anonymous file descriptors. Nested files retain their boundaries. When
normalization is active, unreadable options files and replacements that
cannot be represented in them produce an error.

Output adapters honor the last explicit `-o` or `--output-file`, including
options files. The `nvcc` PTX adapter also recognizes its default output names.
Requested PTX path remapping also applies to `nvcc -o -` and `ptxas -`.
Informational calls such as `--version` skip editing. Binary edits preserve
field sizes. Standalone PTX can change size. Keep options files stable for the
duration of a call and give independent builds separate outputs.

See [the JIT guide](./README.jit.md) for tools that compile, link, or assemble in
process.

TensorRT engine builds through `trtexec` need a separate policy for tactic
selection. GPU timing noise can change which tactics the builder selects, and
a cache miss can trigger fresh profiling. NVIDIA's editable timing cache lets
an application pin the selected tactics.
[TensorRT reproducible builds](https://docs.nvidia.com/deeplearning/tensorrt/latest/inference-library/precision-control.html#algorithm-selection-and-reproducible-builds)
