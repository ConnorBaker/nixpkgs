# CUDA Modules

> [!NOTE]
> This document is meant to help CUDA maintainers understand the structure of
> the CUDA packages in Nixpkgs. It is not meant to be a user-facing document.
> For a user-facing document, see [the CUDA section of the manual](../../../doc/languages-frameworks/cuda.section.md).

The files in this directory are added (in some way) to the `cudaPackages`
package set by [cuda-packages.nix](../../top-level/cuda-packages.nix).

## Top-level directories

- `_cuda`: Fixed-point used to configure, construct, and extend the CUDA package
    set. This includes NVIDIA manifests.
- [`backendStdenv`](backendStdenv) selects the host compiler for NVCC and resolves the target CUDA capabilities.
- `buildRedist`: Contains the logic to build packages using NVIDIA's manifests.
- `packages`: Contains packages which exist in every instance of the CUDA
    package set. These packages are built in a `by-name` fashion and include
    the [CUDA package set tests](packages/tests).

Many redistributable packages are in the `packages` directory. Their presence
ensures that, even if a CUDA package set which no longer includes a given package
is being constructed, the attribute for that package will still exist (but refer
to a broken package). This prevents missing attribute errors as the package set
evolves.

## Distinguished packages

Some packages are purposefully not in the `packages` directory. These are packages
which do not make sense for Nixpkgs, require further investigation, or are otherwise
not straightforward to include. These packages are:

- `cuda`:
  - `collectx_bringup`: missing `libssl.so.1.1` and `libcrypto.so.1.1`; not sure how
    to provide them or what the package does.
  - `cuda_sandbox_dev`: unclear on purpose.
  - `driver_assistant`: we don't use the drivers from the CUDA releases; irrelevant.
  - `mft_autocomplete`: unsure of purpose; contains FHS paths.
  - `mft_oem`: unsure of purpose; contains FHS paths.
  - `mft`: unsure of purpose; contains FHS paths.
  - `nvidia_driver`: we don't use the drivers from the CUDA releases; irrelevant.
- `cudnn`:
  - `cudnn_samples`: requires FreeImage, which is abandoned and not packaged.

> [!NOTE]
>
> When packaging redistributables, prefer `autoPatchelfIgnoreMissingDeps` to providing
> paths to stubs with `extraAutoPatchelfLibs`; the stubs are meant to be used for
> projects where linking against libraries available only at runtime is unavoidable.

## CUDA driver compatibility

NVIDIA's `cuda_compat` backports user-space driver components to supported older kernel drivers.
For package inputs, the first-lookup rules, and how to inspect a built executable, see
[CUDA driver selection](driver-compatibility.md).

The package uses the archive from the CUDA manifest through CUDA 13.3. From CUDA 13.4,
pin the latest `nvidia-driver` release built for that toolkit in the package set.
[Package set pins](../../top-level/cuda-packages.nix) · [Driver manifest update instructions](_cuda/manifests/nvidia-driver/README.md)
