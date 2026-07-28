{
  cuda-library-samples-src,
  cuda_cudart,
  cudaOlder,
  lib,
  libcublas,
  mkSamples,
}:
let
  # The newest pinned revision of CUDALibrarySamples cannot be built against CUDA 12. Its
  # `cuBLAS/utils/cublas_utils.h` defines `getFixedPointWorkspaceSizeInBytes`, taking a
  # `cudaEmulationMantissaControl` and comparing against `CUDA_EMULATION_MANTISSA_CONTROL_DYNAMIC`,
  # at file scope and behind no `#if` -- and nearly every sample in the subtree includes that header,
  # so the failure is not confined to the FP64-emulation projects which actually use the API.
  #
  # Measured rather than inferred, by searching the headers each package set ships: 12.6, 12.8 and
  # 12.9 declare `cudaEmulationMantissaControl` in no header at all, and 13.0, 13.1, 13.2 and 13.3
  # each declare it in one. So the boundary is CUDA 13.0, and on anything older this component takes
  # the previous revision -- which predates the emulation samples entirely and builds cleanly.
  #
  # This is the component the per-revision pin exists for, and the only one which uses it; what the
  # rest of the package set would lose by being pinned back with it is in `cuda-library-samples-src`.
  src =
    if cudaOlder "13" then
      cuda-library-samples-src.revisions."2025-01-27"
    else
      cuda-library-samples-src;

  # Selected by the revision the source names itself, rather than by repeating the date here: a
  # manifest describes the checkout it was generated from, and picking the two independently is how
  # they come to disagree. `sampleManifestCheck` would catch the mismatch, but only after a build.
  manifestPath = ./samples + "/${src.revision}.json";

  # Parsed here as well as by `mkSamples`, because this component narrows its own overrides against
  # the project list; the two read the same path, so they cannot disagree.
  manifest = lib.importJSON manifestPath;

  # Requirements are NOT part of the generated manifest: upstream does not state them reliably. Most
  # READMEs say "All GPUs supported by CUDA Toolkit", the enumerated ones are stale (they list SM 3.0
  # and omit SM 9.0 and later), cuBLASLt ships no READMEs at all, and no sample checks at runtime.
  # They are established by building against the oldest supported package set and by running on real
  # hardware, not by reading upstream's claims.

  # Every cuBLASLt sample includes `cuBLASLt/Common/helpers.h`, which unconditionally includes
  # `cuda_fp4.h`; that header first ships in CUDA 12.8. Measured: every cuBLASLt sample fails
  # identically on 12.6 and builds on 12.8, while the cuBLAS samples beside them build on 12.6.
  cuBLASLtRequirements.minCudaVersion = "12.8";

  # Three of the FP64-emulation samples call `getApproximateFixedPointEmulationWorkspaceSize`, which
  # is defined nowhere in the repository: `cuBLAS/utils/cublas_utils.h` defines
  # `getFixedPointWorkspaceSizeInBytes` beside it and nothing declares the name these three use.
  # nvcc says so plainly -- `identifier "getApproximateFixedPointEmulationWorkspaceSize" is
  # undefined` -- and a grep of the whole checkout finds only the three call sites and no definition.
  #
  # This is not a version boundary in either axis: the missing function is missing from the sample
  # repository rather than from any toolkit, so every package set which builds this checkout fails
  # the same way.
  emulationHelperMissing = sampleRoot: {
    meta.problems.cublasEmulationHelperUndefined = {
      kind = "broken";
      message =
        "Sample ${sampleRoot} calls getApproximateFixedPointEmulationWorkspaceSize, which"
        + " CUDALibrarySamples defines nowhere -- its cuBLAS/utils/cublas_utils.h declares"
        + " getFixedPointWorkspaceSizeInBytes and no such function -- so nvcc reports the identifier"
        + " as undefined. Upstream:"
        + " https://github.com/NVIDIA/CUDALibrarySamples/tree/master/${sampleRoot}";
    };
  };

  # Asked of the manifest rather than of the revision that happens to carry these projects today.
  # `sampleArgs` is checked against the manifest and a key naming a project the checkout does not
  # contain is an error, so the set has to be narrowed somehow -- but narrowing it by comparing
  # `src.revision` against a hard-coded date states the wrong fact twice: it would be wrong for any
  # third pin which also predates these samples, and it says nothing a reader can check. The
  # manifest already records exactly which projects this component builds.
  brokenEmulationSampleRoots = lib.intersectLists (lib.attrNames manifest.samples) (
    map (project: "cuBLAS/Emulation/${project}") [
      "dgemm_dynamic"
      "zgemm_dynamic"
      "gemmEx_dynamic"
    ]
  );

  sampleArgs = {
    # Measured by running the tests on an RTX 4090 (SM 8.9): the FP8 matmul passes there, while both
    # narrow-precision matmuls abort with `cuBLAS API failed`.
    "cuBLASLt/LtFp8Matmul".minCudaCapability = "8.9";
    "cuBLASLt/LtMxfp8Matmul".minCudaCapability = "10.0";
    "cuBLASLt/LtNvfp4Matmul".minCudaCapability = "10.0";
  }
  // lib.genAttrs brokenEmulationSampleRoots emulationHelperMissing;
in
mkSamples {
  component = libcublas;
  inherit
    manifestPath
    sampleArgs
    src
    ;
  subtrees = [
    "cuBLAS"
    "cuBLASLt"
  ];
  buildInputs = [ cuda_cudart ];
  # The version requirement is a property of the whole cuBLASLt subtree rather than of any one
  # project, so it is expressed as a rule; the three above are keyed on the projects they were
  # measured against, and those keys are checked against the manifest.
  sampleArgsFor =
    sampleRoot: lib.optionalAttrs (lib.hasPrefix "cuBLASLt/" sampleRoot) cuBLASLtRequirements;
}
