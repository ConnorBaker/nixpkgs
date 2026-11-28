# CUDA driver selection

`cudaPackages.cuda_compat` supplies NVIDIA’s user-space backport. The kernel driver comes from the host, including in a container. A toolkit helper handles first use by packaged CUDART and other wrapped CUDA libraries. A glibc auditor covers dependencies resolved before application or plugin code runs. Both leave CUDA initialization and device visibility to the application.

## Which driver loads

A bare `libcuda.so.1` lookup reuses a driver already bound by that name in its loader namespace. To qualify for a new binding, a backport must be newer than the release in `/sys/module/nvidia/version` and list that kernel branch in NVIDIA’s format-1 ELF note. The process must also be able to open the `/dev/nvidiactl` character device. Comparing against the kernel can favor a backport over an unloaded library on `LD_LIBRARY_PATH`. An explicit path can load a different provider. The chosen library still needs its dependencies. NVIDIA limits hardware and graphics interoperability support. [NVIDIA forward compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/latest/forward-compatibility.html)

| First request for `libcuda.so.1` | Result |
| --- | --- |
| Direct ELF dependency (`DT_NEEDED`) or `dlopen` with the auditor active | The auditor offers the newest eligible candidate registered in that namespace. With no match, the lookup continues. |
| Packaged shared or static CUDART, or another wrapped vendor library, calls `dlopen` | The helper can supply its own toolkit’s eligible driver even in an unmodified host. An active auditor also sees the bare-name lookup. |
| An unmodified plugin makes its own lookup or links directly to the driver in a process without the auditor | glibc uses the ordinary search path. It resolves the direct dependency before any plugin constructor runs. |

With CUDA 13.3 and 13.5 both loaded on kernel driver 615, the first call through 13.3 used host 615. Calling through 13.5 first used backport 620. With both toolkits registered, the auditor chose 620 for either caller. Loading the runtimes alone left the decision open.

## From package inputs to the running process

- **Build inputs.** `buildInputs = [ cudaPackages.cuda_cudart ];` propagates a native fixup hook through the development output. An explicit `cuda_cudart.out` supplies the SDK without propagating the hook. After autoPatchelf the hook scans target ELF files, skipping the stubs output. It appends the auditor to eligible executables’ `DT_AUDIT` list and writes manifest paths to each participating output’s `nix-support/cuda-driver-selection`. It rewrites a glibc `dlopen` import only when the redistributable supplies its own toolkit policy. GPU checks that run before fixup can use `addDriverRunpath.addDriverToLibraryPath` to expose the NixOS driver. [CUDART outputs](packages/cuda_cudart.nix) · [Redistributable builder](buildRedist/default.nix) · [ELF fixup](packages/cudaDriverSelector/elf/fixup.py)
- **Toolkit helper.** The installer reads NVIDIA’s ELF note and writes the driver release, supported kernel branches and absolute driver path to `nix-support/nix-cuda-compat`. A rewritten import binds to a symbol unique to that toolkit. For an eligible request it opens the SONAME with a private `DT_RPATH` containing only its driver link. glibc reuses an existing binding under its loader lock. Pass-through uses Rust’s explicit `become` tail call, enabled for the wrapper crate, to preserve the caller address glibc uses for namespace, search path and `$ORIGIN`. Static CUDART opens the helper temporarily. The compatibility driver opens archived companions by absolute path so it can use its matching JIT compiler even when an older one is loaded. [Manifest writer](packages/cudaDriverSelector/elf/manifest.py) · [Lookup helper](packages/cudaDriverSelector/lookup.rs) · [glibc’s use of the caller address](https://codebrowser.dev/glibc/glibc/dlfcn/dlopen.c.html)
- **Executable auditor.** glibc reads the executable’s audit list at startup. The auditor verifies an object’s device and inode against `/proc/self/maps` before registering its output index. It withdraws candidates when the output’s last object in that namespace closes. It keeps returned path strings alive for other auditors. Overlapping callbacks or a fork inheriting a busy registry disable further substitutions. Both mechanisms share the Rust eligibility policy. [Auditor](packages/cudaDriverSelector/src/lib.rs) · [Policy](packages/cudaDriverSelector/src/policy.rs)
- **Host libraries.** At Nix glibc’s last default-directory probe, the auditor tries host driver directories. For a missing compiler it tries the verified host driver or companion’s own directory. CUDA Tile, Numba and numba-cuda use a lazy Python adapter. The cuda-bindings extension wraps its own calls at link time. Both can retry through an ELF dependency whose inherited `RPATH` lets the host driver find its compilers. On that retry a host compiler may precede an unloaded compiler on `LD_LIBRARY_PATH`. [Host directories](packages/cudaDriverSelector/host-directories.nix) · [Python adapter](packages/pythonDriverLookup/load-driver.py) · [cuda-bindings wrapper](../python-modules/cuda-bindings/driver-wrap.rs)

## Limits and checks

The auditor requires glibc audit ABI 2 and declines secure execution. The toolkit helper also worked on glibc 2.31. The fully static glibc probe returned CUDA error 304 with both CUDART archives. A plugin manager that controls loading can open the real driver before a directly linked plugin. A public forwarding shim missed driver exports and initialized device visibility too early. [glibc audit ABI change](https://sourceware.org/pipermail/libc-stable/2022-April/001467.html) · [Forwarding prototype](https://github.com/ConnorBaker/nixpkgs/tree/52acfcbd12cb3184257cf6cd16aa4fbfaa499e63/pkgs/development/cuda-modules/prototypes/cuda-compat-shim)

Legacy Tegra and dedicated Orin configurations use host lookup. On generic AArch64 an exposed nvgpu device or module also suppresses automatic selection, including on mixed IGX systems. For an Orin upgrade, put the matching JetPack compatibility libraries on the application’s search path. WSL uses its Windows-provided driver. Tests exercised mounted WSL and Jetson layouts. GPU execution there remains unverified. [JetPack compatibility matrix](https://docs.nvidia.com/cuda/cuda-for-tegra-appnote/index.html#cuda-upgrade-package-supported-jetpack-versions) · [CUDA on WSL](https://docs.nvidia.com/cuda/wsl-user-guide/)

From the repository root, inspect the audit list and manifest paths with the GPU-independent loader fixtures. Cross builds check target ELF metadata and run the lookup cases when the build platform can execute the target. [Fixture](packages/tests/driver-selection/package.nix) · [Runtime cases](packages/tests/driver-selection/check.sh)

```sh
out=$(nix-build --no-out-link -A cudaPackages_13_5.tests.driver-selection)
readelf -Wd "$out/bin/direct" | grep '(AUDIT)'
cat "$out/nix-support/cuda-driver-selection"
```

Hardware runs on an Ubuntu GB10, a NixOS RTX 4090 and a GB10 CDI container produced zero SAXPY error, cuBLAS sum 9 and PTX JIT result 42. On the GB10, context allocation (CUDA error 2) and cuBLAS initialization (status 1) each failed intermittently and succeeded in fresh processes. Their causes remain open. [SAXPY source](packages/saxpy/src/saxpy.cu) · [Earlier experiments and controls](https://github.com/ConnorBaker/nixpkgs/blob/234a5bca4ad4697db2a8efb73ad7b94368233e7d/pkgs/development/cuda-modules/driver-compatibility.md)
