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
- `buildRedist`: Contains the logic to build packages using NVIDIA's manifests.
- `packages`: Contains packages which exist in every instance of the CUDA
    package set. These packages are built in a `by-name` fashion.
- `tests`: Contains tests which can be run against the CUDA package set.

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

### CUDA Compatibility

NVIDIA's forward-compatibility package supplies user-space `libcuda.so.1` and
matching compiler components for supported older host drivers. The CUDA package
set includes `cudaPackages.cuda_compat` when NVIDIA publishes the archive. At
first lookup, the selector compares its user-space release with the running
host kernel driver's release and checks the supported kernel branches. [NVIDIA forward compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/latest/forward-compatibility.html)

#### Source

Up to CUDA 13.3, `cuda_compat` is part of the CUDA manifest. Starting with CUDA
13.4, NVIDIA only lists `cuda_compat_orin` (Jetson) there, and publishes
`cuda_compat` under the `nvidia-driver` redistributable directory instead:

```
https://developer.download.nvidia.com/compute/nvidia-driver/redist/cuda_compat/<redistSystem>/cuda_compat-<redistSystem>-<driverVersion>_cuda<major.minor>-archive.tar.xz
```

The driver manifests list these archives only from driver 620.70.06 (CUDA 13.5)
on, so we maintain manifests containing only `cuda_compat` in
[`_cuda/manifests/nvidia-driver`](./_cuda/manifests/nvidia-driver/README.md),
made by hand for older drivers. Package sets select one with the `nvidia-driver`
key in [cuda-packages.nix](../../top-level/cuda-packages.nix), and `cuda_compat`
uses it when the CUDA manifest has no `cuda_compat` entry. We pick the latest
driver release built for each CUDA release (e.g. 615.71.10 for CUDA 13.4 and
620.70.06 for CUDA 13.5).

#### Runtime selection

The shared CUDA runtime propagates the packaging hook to its consumers. CUDA
redistributables also receive the hook directly. It handles ordinary driver
opens inside vendor libraries and eager dependencies in participating glibc
executables. A stock process loading a directly linked plugin can bind the
host driver before any Nix selection code runs. [Implementation, experiments and limits](driver-compatibility.md)
