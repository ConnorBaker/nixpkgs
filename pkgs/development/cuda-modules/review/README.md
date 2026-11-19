# CUDA integration validation

Package-owned tests are the permanent regressions. `rebuild.nix` selects a CUDA
release and platform pair for integration packages, public interfaces and
compiler regressions. Defaults are CUDA 13.4, an x86-64 builder, an AArch64 HOST
and SM 121a; `--arg cross false` selects native x86-64 and SM 89.

Use the existing Tribuchet hub's store so it schedules builds on its registered
workers. These examples select bounded targets before the full integration:

```sh
nix-build --store ssh-ng://nixos-ext \
  pkgs/development/cuda-modules/review/rebuild.nix \
  -A interfaces.cudnn-frontend
nix-build --store ssh-ng://nixos-ext \
  pkgs/development/cuda-modules/review/rebuild.nix \
  -A regressions.nvcc-cmake --arg cudaCapabilities '[ "8.9" ]'
nix-build --store ssh-ng://nixos-ext \
  pkgs/development/cuda-modules/review/rebuild.nix -A torch
```

Run `-A matrix.regressions` for both `--arg cross true` and `--arg cross false`,
with `--arg cudaCapabilities '[ "8.9" ]'` supported by both CUDA 12.9 and 13.4.
The matrix shares one Nixpkgs import. Run `-A matrix.interfaces` for both platform
pairs with their default capabilities; this includes NVPL CMake tests on
supported hosts and renamed component outputs. `--argstr release 12_9` selects
an individual release. Test groups retain named child tests.

Compilation, linking and installed execution are separate acceptance stages.
Cross-built programs must run on HOST; GPU tests require its real driver outside
the build sandbox. The supported production matrix is Linux x86-64 native and
x86-64→AArch64. Darwin, FreeBSD and MinGW evaluation or script controls do not
establish compiler execution. Three distinct platforms are rejected; this is not
Canadian-cross support.

GPU acceptance requires separate runs on the deployment host. A single-PE NVSHMEM check cannot establish multi-node, RDMA or CUDA IPC behavior.

The [wrapper design](../../../build-support/wrapper-common/README.md) describes how the compiler selects and carries flags across nested invocations. The [CUDA manual](../../../../doc/languages-frameworks/cuda.section.md) describes installed tool and SDK selection.

## nvlink notes and dependency roles

The upstream [nvlink wrapper](../packages/cuda_nvcc/README.md) replaces store
hashes in `.note.nv.tkinfo` after linking. It operates beside NVCC's backend/SDK
wrapper; CUDA 12 retains the upstream `nvvm/lib64` alias needed for device LTO.

`cudaPackages.tests.nvlink-notes` first checks BUILD NVCC's prefix is absent from
target `-L` arguments and HOST libffi is present, then checks the RDC note for store hashes.
Sanitized notes alone cannot prove selection of the correct platform's resources.
The upstream nvlink-output fixture selects SM 100 explicitly for note cleanup.
The `cudaPackages.cuda_nvcc.tests` group also covers options
files, process behavior and direct nvlink use. Cross tests select BUILD's compiler
before embedding executable paths; local HOST overrides do not alter that BUILD
sibling. GPU execution is separate.

## Installed tests

`magma.tests.pkg-config-flags` checks public macro exports during configuration,
including conditional definitions, without compiling MAGMA's implementation.

Triton's `tests.runtime-compilers` compiles and loads C and C++ libraries with
an empty `PATH`, without a GPU. It checks the installed compiler defaults;
explicit `CC` and `CXX` still select caller compilers.

Build `-A torch.tests.tester-cppExtension`, then run
`bin/tester-torch-cpp-extension` on HOST outside stdenv.
`TORCH_CUDA_ARCH_LIST=12.1a` selects Spark. Run Torch's
[cpu-dot.py](../../python-modules/torch/tests/cpu-dot.py) in the installed Python environment.

External driver adapters should expose matching OS NVIDIA libraries, including
NVML where required, rather than an entire foreign distribution's library
directory. Use installed tools and a supported locale; numerical success does
not prove driver registration or transport behavior.
