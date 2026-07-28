# CUDA {#cuda}

Compute Unified Device Architecture (CUDA) is a parallel computing platform and application programming interface (API) model created by NVIDIA. It's commonly used to accelerate computationally intensive problems and has been widely adopted for high-performance computing (HPC) and machine learning (ML) applications.

## User Guide {#cuda-user-guide}

Packages provided by NVIDIA which require CUDA are typically stored in CUDA package sets.

Nixpkgs provides a number of CUDA package sets, each based on a different CUDA release. Top-level attributes that provide access to CUDA package sets follow these naming conventions:

- `cudaPackages_x_y`: A major-minor-versioned package set for a specific CUDA release, where `x` and `y` are the major and minor versions of the CUDA release.
- `cudaPackages_x`: A major-versioned alias to the major-minor-versioned CUDA package set with the latest widely supported major CUDA release.
- `cudaPackages`: An unversioned alias to the major-versioned alias for the latest widely supported CUDA release. The package set referenced by this alias is also referred to as the "default" CUDA package set.

It is recommended to use the unversioned `cudaPackages` attribute. While versioned package sets are available (e.g., `cudaPackages_12_8`), they are periodically removed.

Here are two examples to illustrate the naming conventions:

- If `cudaPackages_12_9` is the latest release in the 12.x series, but core libraries like OpenCV or ONNX Runtime fail to build with it, `cudaPackages_12` may alias `cudaPackages_12_8` instead of `cudaPackages_12_9`.
- If `cudaPackages_13_1` is the latest release, but core libraries like PyTorch or Torch Vision fail to build with it, `cudaPackages` may alias `cudaPackages_12` instead of `cudaPackages_13`.

All CUDA package sets include common CUDA packages like `libcublas`, `cudnn`, `tensorrt`, and `nccl`.

### Configuring Nixpkgs for CUDA {#cuda-configuring-nixpkgs-for-cuda}

CUDA support is not enabled by default in Nixpkgs. To enable CUDA support, make sure Nixpkgs is imported with a configuration similar to the following:

```nix
{ pkgs }:
{
  allowUnfreePredicate = pkgs._cuda.lib.allowUnfreeCudaPredicate;
  cudaCapabilities = [ <target-architectures> ];
  cudaForwardCompat = true;
  cudaSupport = true;
}
```

The majority of CUDA packages are unfree, so either `allowUnfreePredicate` or `allowUnfree` should be set.

The `cudaSupport` configuration option is used by packages to conditionally enable CUDA-specific functionality. This configuration option is commonly used by packages which can be built with or without CUDA support.

The `cudaCapabilities` configuration option specifies a list of CUDA capabilities. Packages may use this option to control device code generation to take advantage of architecture-specific functionality, speed up compile times by producing less device code, or slim package closures. For example, you can build for Ada Lovelace GPUs with `cudaCapabilities = [ "8.9" ];`. If `cudaCapabilities` is not provided, the default value is calculated per-package set, derived from a list of GPUs supported by that CUDA version. Please consult [supported GPUs](https://en.wikipedia.org/wiki/CUDA#GPUs_supported) for specific cards. Library maintainers should consult [NVCC Docs](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/) and its release notes.

::: {.caution}
Certain CUDA capabilities are not targeted by default, including capabilities belonging to the Jetson family of devices (e.g. `8.7`, which corresponds to the Jetson Orin) or non-baseline feature-sets (e.g. `9.0a`, which corresponds to the Hopper exclusive feature set). If you need to target these capabilities, you must explicitly set `cudaCapabilities` to include them.
:::

The `cudaForwardCompat` boolean configuration option determines whether PTX support for future hardware is enabled.

### Modifying CUDA package sets {#cuda-modifying-cuda-package-sets}

CUDA package sets are defined in `pkgs/top-level/cuda-packages.nix`. A CUDA package set is created by `callPackage`-ing `pkgs/development/cuda-modules/default.nix` with an attribute set `manifests`, containing NVIDIA manifests for each redistributable. The manifests for supported redistributables are available through `_cuda.manifests` and live in `pkgs/development/cuda-modules/_cuda/manifests`.

The majority of the CUDA package set tooling is available through the top-level attribute set `_cuda`, a fixed-point defined outside the CUDA package sets. As a fixed-point, `_cuda` should be modified through its `extend` attribute.

::: {.caution}
As indicated by the underscore prefix, `_cuda` is an implementation detail and no guarantees are provided with respect to its stability or API. The `_cuda` attribute set is exposed only to ease creation or modification of CUDA package sets by expert, out-of-tree users.
:::

Out-of-tree modifications of packages should use `overrideAttrs` to make any necessary modifications to the package expression.

::: {.note}
The `_cuda` attribute set previously exposed `fixups`, an attribute set mapping from package name (`pname`) to a `callPackage`-compatible expression which provided to `overrideAttrs` on the result of a generic redistributable builder. This functionality has been removed in favor of including full package expressions for each redistributable package to ensure consistent attribute set membership across supported CUDA releases, platforms, and configurations.
:::

### Extending CUDA package sets {#cuda-extending-cuda-package-sets}

CUDA package sets are scopes and provide the usual `overrideScope` attribute for overriding package attributes (see the note about `_cuda` in [Configuring CUDA package sets](#cuda-modifying-cuda-package-sets)).

Inspired by `pythonPackagesExtensions`, the `_cuda.extensions` attribute is a list of extensions applied to every version of the CUDA package set, allowing modification of all versions of the CUDA package set without needing to know their names or explicitly enumerate and modify them. As an example, disabling `cuda_compat` across all CUDA package sets can be accomplished with this overlay:

```nix
final: prev: {
  _cuda = prev._cuda.extend (
    _: prevAttrs: {
      extensions = prevAttrs.extensions ++ [ (_: _: { cuda_compat = null; }) ];
    }
  );
}
```

Redistributable packages are constructed by the `buildRedist` helper; see `pkgs/development/cuda-modules/buildRedist/default.nix` for the implementation.

### Using `cudaPackages` {#cuda-using-cudapackages}

::: {.caution}
A non-trivial amount of CUDA package discoverability and usability relies on the various setup hooks used by a CUDA package set. As a result, users will likely encounter issues trying to perform builds within a `devShell` without manually invoking phases.
:::

To use one or more CUDA packages in an expression, give the expression a `cudaPackages` parameter, and in case CUDA support is optional, add a `config` and `cudaSupport` parameter:

```nix
{
  config,
  cudaSupport ? config.cudaSupport,
  cudaPackages,
}:
<package-expression>
```

In your package's derivation arguments, it is _strongly_ recommended that the following are set:

```nix
{
  __structuredAttrs = true;
  strictDeps = true;
}
```

These settings ensure that the CUDA setup hooks function as intended.

When using `callPackage`, you can choose to pass in a different variant, e.g. when a package requires a specific version of CUDA:

```nix
{ mypkg = callPackage { cudaPackages = cudaPackages_12_6; }; }
```

::: {.caution}
Overriding the CUDA package set for a package may cause inconsistencies, because the override does not affect its direct or transitive dependencies. As a result, it is easy to end up with a package that use a different CUDA package set than its dependencies. If possible, it is recommended that you change the default CUDA package set globally, to ensure a consistent environment.
:::

### Nixpkgs CUDA variants {#cuda-nixpkgs-cuda-variants}

Nixpkgs CUDA variants are provided primarily for the convenience of selecting CUDA-enabled packages by attribute path. As an example, the `pkgsForCudaArch` collection of CUDA Nixpkgs variants allows you to access an instantiation of OpenCV with CUDA support for an Ada Lovelace GPU with the attribute path `pkgsForCudaArch.sm_89.opencv`, without needing to modify the `config` provided when importing Nixpkgs.

::: {.caution}
Nixpkgs variants are not free: they require re-evaluating Nixpkgs. Where possible, import Nixpkgs once, with the desired configuration.
:::

#### Using `cudaPackages.pkgs` {#cuda-using-cudapackages-pkgs}

Each CUDA package set has a `pkgs` attribute, which is a variant of Nixpkgs in which the enclosing CUDA package set becomes the default. This was done primarily to avoid package set leakage, wherein a member of a non-default CUDA package set has a (potentially transitive) dependency on a member of the default CUDA package set.

::: {.note}
Package set leakage is a common problem in Nixpkgs and is not limited to CUDA package sets.
:::

As an added benefit of `pkgs` being configured this way, building a package with a non-default version of CUDA is as simple as accessing an attribute. As an example, `cudaPackages_12_8.pkgs.opencv` provides OpenCV built against CUDA 12.8.

#### Using `pkgsCuda` {#cuda-using-pkgscuda}

The `pkgsCuda` attribute set is a variant of Nixpkgs configured with `cudaSupport = true;` and `rocmSupport = false`. It is a convenient way to access a variant of Nixpkgs configured with the default set of CUDA capabilities.

#### Using `pkgsForCudaArch` {#cuda-using-pkgsforcudaarch}

The `pkgsForCudaArch` attribute set maps CUDA architectures (e.g., `sm_89` for Ada Lovelace or `sm_90a` for architecture-specific Hopper) to Nixpkgs variants configured to support exactly that architecture. As an example, `pkgsForCudaArch.sm_89` is a Nixpkgs variant extending `pkgs` and setting the following values in `config`:

```nix
{
  cudaSupport = true;
  cudaCapabilities = [ "8.9" ];
  cudaForwardCompat = false;
}
```

::: {.note}
In `pkgsForCudaArch`, the `cudaForwardCompat` option is set to `false` because exactly one CUDA architecture is supported by the corresponding Nixpkgs variant. Furthermore, some architectures, including architecture-specific feature sets like `sm_90a`, cannot be built with forward compatibility.
:::

::: {.caution}
Not every version of CUDA supports every architecture!

To illustrate: support for Blackwell (e.g., `sm_100`) was added in CUDA 12.8. Assume our Nixpkgs' default CUDA package set is to CUDA 12.6. Then the Nixpkgs variant available through `pkgsForCudaArch.sm_100` is useless, since packages like `pkgsForCudaArch.sm_100.opencv` and `pkgsForCudaArch.sm_100.python3Packages.torch` will try to generate code for `sm_100`, an architecture unknown to CUDA 12.6. In that case, you should use `pkgsForCudaArch.sm_100.cudaPackages_12_8.pkgs` instead (see [Using `cudaPackages.pkgs`](#cuda-using-cudapackages-pkgs) for more details).
:::

The `pkgsForCudaArch` attribute set makes it possible to access packages built for a specific architecture without needing to manually call `pkgs.extend` and supply a new `config`. As an example, `pkgsForCudaArch.sm_89.python3Packages.torch` provides PyTorch built for Ada Lovelace GPUs.

### Running Docker or Podman containers with CUDA support {#cuda-docker-podman}

It is possible to run Docker or Podman containers with CUDA support. The recommended mechanism to perform this task is to use the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html).

The NVIDIA Container Toolkit can be enabled in NixOS like follows:

```nix
{ hardware.nvidia-container-toolkit.enable = true; }
```

This will automatically enable a service that generates a CDI specification (located at `/var/run/cdi/nvidia-container-toolkit.json`) based on the auto-detected hardware of your machine. You can check this service by running:

```ShellSession
$ systemctl status nvidia-container-toolkit-cdi-generator.service
```

::: {.note}
Depending on what settings you had already enabled in your system, you might need to restart your machine in order for the NVIDIA Container Toolkit to generate a valid CDI specification for your machine.
:::

Once that a valid CDI specification has been generated for your machine on boot time, both Podman and Docker (> 25) will use this spec if you provide them with the `--device` flag:

```ShellSession
$ podman run --rm -it --device=nvidia.com/gpu=all ubuntu:latest nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 4090 (UUID: <REDACTED>)
GPU 1: NVIDIA GeForce RTX 2080 SUPER (UUID: <REDACTED>)
```

```ShellSession
$ docker run --rm -it --device=nvidia.com/gpu=all ubuntu:latest nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 4090 (UUID: <REDACTED>)
GPU 1: NVIDIA GeForce RTX 2080 SUPER (UUID: <REDACTED>)
```

You can check all the identifiers that have been generated for your auto-detected hardware by checking the contents of the `/var/run/cdi/nvidia-container-toolkit.json` file:

```ShellSession
$ nix run nixpkgs#jq -- -r '.devices[].name' < /var/run/cdi/nvidia-container-toolkit.json
0
1
all
```

#### Specifying what devices to expose to the container {#cuda-specifying-what-devices-to-expose-to-the-container}

You can choose what devices are exposed to your containers by using the identifier on the generated CDI specification. Like follows:

```ShellSession
$ podman run --rm -it --device=nvidia.com/gpu=0 ubuntu:latest nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 4090 (UUID: <REDACTED>)
```

You can repeat the `--device` argument as many times as necessary if you have multiple GPU's and you want to pick up which ones to expose to the container:

```ShellSession
$ podman run --rm -it --device=nvidia.com/gpu=0 --device=nvidia.com/gpu=1 ubuntu:latest nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 4090 (UUID: <REDACTED>)
GPU 1: NVIDIA GeForce RTX 2080 SUPER (UUID: <REDACTED>)
```

::: {.note}
By default, the NVIDIA Container Toolkit will use the GPU index to identify specific devices. You can change the way to identify what devices to expose by using the `hardware.nvidia-container-toolkit.device-name-strategy` NixOS attribute.
:::

#### Using docker-compose {#cuda-using-docker-compose}

It's possible to expose GPUs to a `docker-compose` environment as well. With a `docker-compose.yaml` file like follows:

```yaml
services:
  some-service:
    image: ubuntu:latest
    command: sleep infinity
    deploy:
      resources:
        reservations:
          devices:
          - driver: cdi
            device_ids:
            - nvidia.com/gpu=all
```

In the same manner, you can pick specific devices that will be exposed to the container:

```yaml
services:
  some-service:
    image: ubuntu:latest
    command: sleep infinity
    deploy:
      resources:
        reservations:
          devices:
          - driver: cdi
            device_ids:
            - nvidia.com/gpu=0
            - nvidia.com/gpu=1
```

## Contributing {#cuda-contributing}

::: {.warning}
This section of the docs is still very much in progress. Feedback is welcome in GitHub Issues tagging @NixOS/cuda-maintainers or on [Matrix](https://matrix.to/#/#cuda:nixos.org).
:::

### Package set maintenance {#cuda-package-set-maintenance}

The CUDA Toolkit is a suite of CUDA libraries and software meant to provide a development environment for CUDA-accelerated applications. Until the release of CUDA 11.4, NVIDIA had only made the CUDA Toolkit available as a multi-gigabyte runfile installer. From CUDA 11.4 and onwards, NVIDIA has also provided CUDA redistributables (“CUDA-redist”): individually packaged CUDA Toolkit components meant to facilitate redistribution and inclusion in downstream projects. These packages are available in the [`cudaPackages`](https://search.nixos.org/packages?channel=unstable&type=packages&query=cudaPackages) package set.

While the monolithic CUDA Toolkit runfile installer is no longer provided, [`cudaPackages.cudatoolkit`](https://search.nixos.org/packages?channel=unstable&type=packages&query=cudaPackages.cudatoolkit) provides a `symlinkJoin`-ed approximation which common libraries. The use of [`cudaPackages.cudatoolkit`](https://search.nixos.org/packages?channel=unstable&type=packages&query=cudaPackages.cudatoolkit) is discouraged: all new projects should use the CUDA redistributables available in [`cudaPackages`](https://search.nixos.org/packages?channel=unstable&type=packages&query=cudaPackages) instead, as they are much easier to maintain and update.

#### Updating redistributables {#cuda-updating-redistributables}

Whenever a new version of a redistributable manifest is made available:

1. Check the corresponding README.md in `pkgs/development/cuda-modules/_cuda/manifests` for the URL to use when vendoring manifests.
2. Update the manifest version used in construction of each CUDA package set in `pkgs/top-level/cuda-packages.nix`.
3. Update package expressions in `pkgs/development/cuda-modules/packages`.

Updating package expressions amounts to:

- adding fixes conditioned on newer releases, like added or removed dependencies
- adding package expressions for new packages
- updating `passthru.brokenConditions` and `passthru.badPlatformsConditions` with various constraints, (e.g., new releases removing support for various architectures)

#### Updating supported compilers and GPUs {#cuda-updating-supported-compilers-and-gpus}

1. Update `nvccCompatibilities` in `pkgs/development/cuda-modules/_cuda/db/bootstrap/nvcc.nix` to include the newest release of NVCC, as well as any newly supported host compilers.
2. Update `cudaCapabilityToInfo` in `pkgs/development/cuda-modules/_cuda/db/bootstrap/cuda.nix` to include any new GPUs supported by the new release of CUDA.

#### Updating the CUDA package set {#cuda-updating-the-cuda-package-set}

::: {.note}
Changing the default CUDA package set should occur in a separate PR, allowing time for additional testing.
:::

::: {.warning}
As described in [Using `cudaPackages.pkgs`](#cuda-using-cudapackages-pkgs), the current implementation fix for package set leakage involves creating a new instance for each non-default CUDA package sets. As such, We should limit the number of CUDA package sets which have `recurseForDerivations` set to true: `lib.recurseIntoAttrs` should only be applied to the default CUDA package set.
:::

1. Include a new `cudaPackages_<major>_<minor>` package set in `pkgs/top-level/cuda-packages.nix` and inherit it in `pkgs/top-level/all-packages.nix`.
2. Successfully build the closure of the new package set, updating expressions in `pkgs/development/cuda-modules/packages` as needed. Below are some common failures:

| Unable to ...  | During ...                       | Reason                                           | Solution                   | Note                                                         |
| -------------- | -------------------------------- | ------------------------------------------------ | -------------------------- | ------------------------------------------------------------ |
| Find headers   | `configurePhase` or `buildPhase` | Missing dependency on a `dev` output             | Add the missing dependency | The `dev` output typically contains the headers               |
| Find libraries | `configurePhase`                 | Missing dependency on a `dev` output             | Add the missing dependency | The `dev` output typically contains CMake configuration files |
| Find libraries | `buildPhase` or `patchelf`       | Missing dependency on a `lib` or `static` output | Add the missing dependency | The `lib` or `static` output typically contains the libraries |

::: {.note}
Two utility derivations ease testing updates to the package set:

- `cudaPackages.tests.redists-unpacked`: the `src` of each redistributable package unpacked and `symlinkJoin`-ed
- `cudaPackages.tests.redists-installed`: each output of each redistributable package `symlinkJoin`-ed
:::

Failure to run the resulting binary is typically the most challenging to diagnose, as it may involve a combination of the aforementioned issues. This type of failure typically occurs when a library attempts to load or open a library it depends on that it does not declare in its `DT_NEEDED` section. Try the following debugging steps:

1. First ensure that dependencies are patched with [`autoAddDriverRunpath`](https://search.nixos.org/packages?channel=unstable&type=packages&query=autoAddDriverRunpath).
2. Failing that, try running the application with [`nixGL`](https://github.com/guibou/nixGL) or a similar wrapper tool.
3. If that works, it likely means that the application is attempting to load a library that is not in the `RPATH` or `RUNPATH` of the binary.

### Writing tests {#cuda-writing-tests}

::: {.caution}
The existence of `passthru.testers` and `passthru.tests` should be considered an implementation detail -- they are not meant to be a public or stable interface.
:::

In general, there are two attribute sets in `passthru` that are used to build and run tests for CUDA packages: `passthru.testers` and `passthru.tests`. Each attribute set may contain an attribute set named `cuda`, which contains CUDA-specific derivations. The `cuda` attribute set is used to separate CUDA-specific derivations from those which support multiple implementations (e.g., OpenCL, ROCm, etc.) or have different licenses. For an example of such generic derivations, see the `magma` package.

::: {.note}
Derivations are nested under the `cuda` attribute due to an OfBorg quirk: if evaluation fails (e.g., because of unfree licenses), the entire enclosing attribute set is discarded. This prevents other attributes in the set from being discovered, evaluated, or built.
:::

#### `passthru.testers` {#cuda-passthru-testers}

Attributes added to `passthru.testers` are derivations which produce an executable which runs a test. The produced executable should:

- Take care to set up the environment, make temporary directories, and so on.
- Be registered as the derivation's `meta.mainProgram` so that it can be run directly.

::: {.note}
Testers which always require CUDA should be placed in `passthru.testers.cuda`, while those which are generic should be placed in `passthru.testers`.
:::

The `passthru.testers` attribute set allows running tests outside the Nix sandbox. There are a number of reasons why this is useful, since such a test:

- Can be run on non-NixOS systems, when wrapped with utilities like `nixGL` or `nix-gl-host`.
- Has network access patterns which are difficult or impossible to sandbox.
- Is free to produce output which is not deterministic, such as timing information.

#### `passthru.tests` {#cuda-passthru-tests}

Attributes added to `passthru.tests` are derivations which run tests inside the Nix sandbox. Tests should:

- Use the executables produced by `passthru.testers`, where possible, to avoid duplication of test logic.
- Include `requiredSystemFeatures = [ "cuda" ];`, possibly conditioned on the value of `cudaSupport` if they are generic, to ensure that they are only run on systems exposing a CUDA-capable GPU.

::: {.note}
Tests which always require CUDA should be placed in `passthru.tests.cuda`, while those which are generic should be placed in `passthru.tests`.
:::

This is useful for tests which are deterministic (e.g., checking exit codes) and which can be provided with all necessary resources in the sandbox.

#### Component samples {#cuda-component-samples}

Redistributable components are unpacked rather than compiled, so the programs which exercise them cannot be built as part of the component itself. They are defined in `pkgs/development/cuda-modules/packages/tests/<component>-samples`, taking the component as an ordinary `callPackage` argument, and appear as `cudaPackages.tests.<component>-samples`. Eight components have samples: `libcublas`, `libcudss`, `libcufft`, `libcurand`, `libcusolver`, `libcusparse`, `libnpp` and `libnvjpeg`.

Most such programs come from [CUDALibrarySamples](https://github.com/NVIDIA/CUDALibrarySamples), which provides one self-contained CMake project per example rather than a single build covering them all. `buildSample` builds one such project; `mkSamples` calls it once per entry in the component's checked-in manifest, which lives in the same directory:

```nix
# pkgs/development/cuda-modules/packages/tests/libcublas-samples/package.nix
{
  cuda_cudart,
  lib,
  libcublas,
  mkSamples,
}:
mkSamples {
  component = libcublas;
  manifest = lib.importJSON ./samples.json;
  manifestPath = ./samples.json;
  buildInputs = [ cuda_cudart ];
}
```

Build one derivation per project rather than one per component: projects build in parallel, each caches on its own, and a project which stops compiling takes down only its own tests.

`cudaPackages.tests.<component>-samples` is a `recurseIntoAttrs` set whose leaves are the sandboxed tests, one per sample executable, keyed `<project>-<program>` -- for example `cudaPackages.tests.libcublas-samples."cuBLAS-Level-3-gemm-cublas_gemm_example"`. Keying on the executable alone would silently lose tests: a project may build several (`cuBLAS/Level-1/dot` builds `cublas_dot_example` and `cublas_dotc_example`) and two projects may build executables of the same name, which cuFFT does twice over between `cuFFT/lto_callback_window_1d` and `cuFFT/lto_ea`.

Each test is built from two further derivations, which hang off its `passthru` rather than sitting beside it, so that everything found by recursing into the set is a check rather than an ingredient of one:

- the test itself runs the executable inside the sandbox;
- its `passthru.tester` is that executable -- the sample program and its arguments wrapped into a script registered as `meta.mainProgram` -- so the same run can be reproduced outside the sandbox, under `nixGL` on a non-NixOS host;
- the tester's `passthru.sample` is the compiled project.

Each of the three can fail, be cached and be rebuilt on its own; changing an invocation does not force a recompile. The manifest drift check described in [Enumerating samples](#cuda-enumerating-samples) is a leaf of the same set, under the reserved name `manifest` -- it is a check on the manifest which lists these very projects -- so whatever builds the set builds it too.

The component itself carries the whole set, so that tooling which builds the tests of a changed package finds them:

```nix
{ passthru.tests = tests.libcublas-samples; }
```

::: {.caution}
Do not attach these to the component's `passthru` under a name which collides with one of its outputs. Redistributable outputs are determined by the upstream archive rather than by us, and several components -- `cuda_cupti` among them -- ship a `samples` output which a `passthru.samples` would silently shadow.
:::

::: {.note}
Testers and tests for a redistributable component are **not** nested under a `cuda` attribute. That convention exists to separate CUDA-specific tests from other backends on a package which supports several, and to stop an unfree member from discarding free siblings under OfBorg. Neither applies to a component which is itself part of CUDA: every test of one is CUDA-specific and equally unfree.
:::

These tests belong to the CUDA package set which owns them. They are reachable at `cudaPackages.tests.<component>-samples.<project>-<program>` within whichever CUDA package set you are using, and `cudaPackages.tests` is traversable, so walking it reaches every component's samples. There is no separate top-level enumeration, and none should be added: a hand-written cross-product over versioned package set *names* cannot track the sets which actually exist, because several of those names alias the same set while other live sets have no alias at all, which makes such a list redundant and incomplete at the same time.

Two aggregates give the parts which need no GPU a single name to build: `cudaPackages.tests.sample-manifests` collects the eight manifest drift checks, and `cudaPackages.tests.samples-built` compiles every available sample, reaching the samples through the tests which run them. Both name the components they cover rather than discovering them by filtering `cudaPackages`. Filtering forces every attribute of the package set, deprecated aliases included, to ask a question about eight of them, and it reports success on an empty result if the attribute it filters on is ever renamed. Adding a component means adding a line to each, alongside the new directory under `packages/tests`.

#### Enumerating samples {#cuda-enumerating-samples}

Every sample project in the component's subtrees is packaged, not a hand-picked subset. The eight manifests describe 177 projects between them -- 79 under `libcublas`, 7 `libcudss`, 9 `libcufft`, 9 `libcurand`, 30 `libcusolver`, 34 `libcusparse`, 4 `libnpp` and 5 `libnvjpeg` -- which build 218 executables.

Since CUDALibrarySamples has no index and reading the checkout at evaluation time would be import-from-derivation, the set of projects is recovered by `buildSample/manifest.py` and checked in beside the sample package. `generate` writes the new manifest to standard output, and `--merge` reads the old one, so redirect to a new file and move it into place rather than redirecting over the file being read:

```ShellSession
$ manifest.py generate --merge samples.json <checkout> cuBLAS cuBLASLt > samples.json.new
$ mv samples.json.new samples.json
```

Which projects exist is enumerated exactly, by walking the subtrees for `CMakeLists.txt`. Which executables each project builds is recovered by parsing CMake, which is a heuristic -- so the parse is never what certifies correctness. Four checks are, and none of them needs a GPU:

- `buildSample` installs the declared `programs` by name and fails if one is missing, catching an upstream rename or removal.
- `buildSample` also fails on any executable the project built that `programs` does not declare, catching an upstream addition inside a known project. Between them these two make CMake itself, rather than the parser, the authority on a project's executables.
- The manifest drift check rescans the subtrees -- passed to it independently, so a manifest cannot narrow its own scope -- and compares them against the manifest, catching a project added or removed upstream. It reports how many projects it verified and fails if that number is zero, since a check which happens to verify nothing would otherwise pass.
- `cudaPackages.tests.samples-built` compiles every available sample, so the checks above actually run. A guarantee which only holds for attributes nobody builds is not a guarantee.

Availability is not total, and the docs should not claim it is. On the default package set 174 of the 177 projects build; three are marked broken with a measured `meta.problems` entry rather than being dropped from the manifest -- `cuDSS/simple_batch`, `cuFFT/lto_ea` and `NPP/watershedSegmentation` -- which leaves 213 tests. Samples are selected on `meta.available` rather than built wholesale, and the count of what remains is asserted, so a mistake which made everything unavailable empties the aggregate loudly instead of shrinking it quietly.

A project whose targets are built in a `foreach` over a configure-time list cannot be named by any static parse. Those are marked `"handDeclared": true` in the manifest with their `programs` filled in by hand; `check` reports them separately and excludes them from the verified count rather than counting them as confirmed, and `--merge` will carry a hand-written list forward only for a project which is still unparseable. A project which stops being parseable therefore comes back empty and fails generation, instead of silently inheriting its old answer. One project is hand-declared today: `cuDSS/simple_mgmn_mode`, which builds one executable per communication backend.

#### Sample requirements {#cuda-sample-requirements}

`minCudaVersion`, `maxCudaVersion` and `minCudaCapability` express what a sample needs. A sample reports a `meta.problems` entry -- naming the requirement and the values which failed to meet it -- when the package set's CUDA is too old (`cudaVersionTooOld`) or too new (`cudaVersionTooNew`) or no configured capability qualifies (`noUsableCudaCapability`), and it is compiled for exactly the capabilities which do qualify.

`mkSamples` takes `sampleArgs`, a table from `sampleRoot` to extra arguments for that one sample -- requirements, but equally extra `buildInputs`, `cmakeFlags` or a `postPatch`:

```nix
{
  sampleArgs = {
    "cuBLASLt/LtFp8Matmul".minCudaCapability = "8.9";
    "NPP/watershedSegmentation".maxCudaVersion = "12.6";
  };
}
```

Its keys are checked against the manifest, so a key naming no project fails evaluation instead of being discarded in silence. That check is why the table is preferred: a mistyped key carrying a `minCudaCapability` would otherwise leave the sample building happily while its test quietly lost the `cuda-sm-<capability>` requirement which keeps it off a GPU that cannot run it.

For a rule which applies to a family of projects rather than to one -- every cuBLASLt sample needs CUDA 12.8 -- `mkSamples` also takes `sampleArgsFor`, a function of `sampleRoot`. It has no key to check against the manifest, so use it only where a table would mean repeating the same value across a subtree:

```nix
{
  sampleArgsFor =
    sampleRoot: lib.optionalAttrs (lib.hasPrefix "cuBLASLt/" sampleRoot) { minCudaVersion = "12.8"; };
}
```

Key both on `sampleRoot` rather than on the manifest key, so that a change to how keys are derived cannot silently detach a requirement from its sample. Arguments merge rather than replace -- lists concatenate, attribute sets merge recursively, `pre*`/`post*` hooks append, and anything else is an error -- so neither a family rule nor a per-sample override can silently drop the `buildInputs` or patches every sample depends on, or displace the other. Prefer a per-sample override to a component-wide one: a linker flag added for one sample which needs it should not apply to the other thirty-three which do not.

::: {.important}
Requirements are curated by hand and deliberately excluded from the generated manifest, because upstream does not state them reliably: most READMEs say "All GPUs supported by CUDA Toolkit", the ones which enumerate architectures are stale (listing SM 3.0 while omitting SM 9.0 and later), cuBLASLt ships no READMEs at all, and no sample checks its requirements at runtime. Establish them by building against the oldest supported package set and by running on real hardware -- not by reading upstream's claims, and not from memory.
:::

Compiling for a capability is verified rather than assumed. Some of the per-library example helpers -- `add_cublas_example` and its cuRAND and cuSOLVER counterparts -- set `CUDA_ARCHITECTURES OFF` on each target they define, which silently discards `CMAKE_CUDA_ARCHITECTURES`; `buildSample` patches that out where it finds it and its `installCheckPhase` reads the architectures back out of the built binaries with `cuobjdump`. The check is exact in both directions: the SASS present must be exactly the set requested, and a capability present only as PTX is a failure rather than a pass, since these binaries are run on real GPUs by the derived tests and JIT compilation is not a substitute. Samples which embed no device code at all are skipped.

#### Running capability-gated tests {#cuda-running-capability-gated-tests}

Every sample test requires the `cuda` system feature, and the builder has to expose the driver and the device nodes to the sandbox. On NixOS that is `programs.nix-required-mounts.presets.nvidia-gpu.enable`, which also adds `cuda` to `nix.settings.system-features`.

A test derived from a sample with a `minCudaCapability` requires a capability feature in addition -- `cuda-sm-89` for `"8.9"`, the dot dropped. Building for a capability and running on it are different questions: the package set compiles for every configured capability, so a Blackwell-only sample builds happily on a machine which cannot execute it.

System features match exactly, so a minimum cannot be expressed by the requirement alone: a builder must advertise every capability it is able to run. Which capabilities those are depends on the flavour of each, and there are three. A baseline capability such as `8.9` is advertised by every GPU at or above it. An architecture-specific one such as `9.0a` runs on SM 9.0 and on nothing else, not even on a later minor version of the same family, so it is advertised by SM 9.0 alone. A family-specific one such as `10.0f` -- a family being a major compute capability version -- is advertised by every GPU in the 10.x family at or above 10.0, which is to say by SM 10.0, 10.1 and 10.3, but by no 11.x or 12.x GPU. The resulting list is long: an RTX 4090 at SM 8.9 advertises thirteen features, from `cuda-sm-35` up to `cuda-sm-89`. Derive it with the helper rather than writing it out by hand:

```nix
{
  nix.settings.system-features = [
    "big-parallel"
    "cuda"
  ]
  ++ pkgs._cuda.lib.getCudaSystemFeatures [ "8.9" ];
}
```

The argument is a list, for a machine with more than one kind of GPU, and the result is the union of the closures rather than the closure of the most capable: a host with both a 9.0 and a 10.0 can run `sm_90a`, which a host with only the 10.0 cannot. It throws on a capability Nixpkgs does not know, and on a suffixed one -- no GPU *is* `9.0a`, that names code an SM 9.0 GPU can run -- so a typo or a category error fails evaluation rather than producing a builder which is quietly never chosen.

The requirement and the advertisement are both named by `_cuda.lib.mkCudaSystemFeature`, and must be: Nix matches system features by exact string, and two spellings which drift apart do not fail the build. They leave every gated test unschedulable, which is indistinguishable from owning no builder that can run it. `cudaPackages.tests.cuda-system-features` checks the closure's properties for the same reason.

What the closure deliberately is not is binary compatibility. A cubin loads within a major capability version at a minor version at least as high, and needs PTX and a JIT beyond that; this closure instead answers whether a GPU meets a stated minimum, which is what a sample's `minCudaCapability` is and what a builder is chosen by. The code the builder runs was compiled for its own capabilities by the package set, so the cubin question does not arise. `getCudaSystemFeatures` documents this alongside the one thing `_cuda.db` genuinely does not record: whether one baseline capability's features contain another's, which the version ordering does not imply and which the Jetson entries are the first to break.

Without this, capability-gated tests are refused a builder rather than failing obscurely partway through.

Of the 213 tests available on the default package set, 199 pass on an RTX 4090 builder configured as above. The remaining 14 fail for reasons outside this machinery and have not yet been expressed as requirements: seven want input data the sample does not ship, two want a source path present at run time, two want a multi-rank launcher, and three want a `cuda-sm-*` feature above what an RTX 4090 can advertise.
