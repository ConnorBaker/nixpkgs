{
  _cuda,
  boost,
  buildPythonPackage,
  cudaPackages,
  fetchFromGitHub,
  lib,
  mako,
  numpy,
  platformdirs,
  pytestCheckHook,
  python,
  pytools,
  setuptools,
  wheel,
  writableTmpDirAsHomeHook,
}:
let
  inherit (_cuda.lib) dropDots;
  inherit (cudaPackages)
    cuda_cudart
    cuda_nvcc
    cuda_profiler_api
    libcurand
    ;
  inherit (lib)
    getFirstOutput
    getLib
    licenses
    maintainers
    teams
    ;
in
buildPythonPackage {
  __structuredAttrs = true;

  pname = "pycuda";
  version = "2025.1.2";

  pyproject = true;

  src = fetchFromGitHub {
    owner = "inducer";
    repo = "pycuda";
    tag = "v2025.1.2";
    hash = "sha256-JMGVNjiKCAno29df8Zk3njvpgvz9JE8mb0HeJMVTnCQ=";
    # Use the vendored compyte source rather than tracking it as a separate dependency.
    # As an added bonus, this should unbreak the update script added by buildPythonPackage.
    fetchSubmodules = true;
  };

  build-system = [
    setuptools
    wheel
  ];

  nativeBuildInputs = [
    cuda_nvcc
  ];

  prePatch = ''
    nixLog "patching $PWD/pycuda/compiler.py::DynamicModule.__init__ to fix path to CUDA runtime library"
    substituteInPlace "$PWD/pycuda/compiler.py" \
      --replace-fail \
        'cuda_libdir=None,' \
        'cuda_libdir="${getLib cuda_cudart}/lib",'
  '';

  dependencies = [
    boost
    mako
    numpy
    platformdirs
    pytools
  ];

  buildInputs = [
    cuda_cudart
    cuda_nvcc
    cuda_profiler_api
    libcurand
  ];

  configureScript = "./configure.py";

  # configure.py doesn't support the installation directory arguments _multioutConfig sets.
  # The other argument provided by configurePhase, like --prefix, --enable-shared, and --disable-static are ignored.
  setOutputFlags = false;

  configureFlags = [
    # The expected boost python library name is something like boost_python-py313, but our library name doesn't have a
    # hyphen. The pythonVersion is already a major-minor version, so we just need to remove the dot.
    "--no-use-shipped-boost"
    "--boost-python-libname=boost_python${dropDots python.pythonVersion}"
    # Provide paths to our CUDA libraries.
    "--cudadrv-lib-dir=${getFirstOutput [ "stubs" "lib" ] cuda_cudart}/lib/stubs"
    "--cudart-lib-dir=${getLib cuda_cudart}/lib"
    "--curand-lib-dir=${getLib libcurand}/lib"
  ];

  # Requires access to libcuda.so.1 which is provided by the driver
  doCheck = false;

  # From setup.py
  pythonImportsCheck = [
    "pycuda"
    # "pycuda.gl" # Requires the CUDA driver
    "pycuda.sparse"
    "pycuda.compyte"
  ];

  # TODO: Split into testers and tests.
  # NOTE: Tests take 23m to run on a 4090 and require 18GB of VRAM.
  passthru.tests.test = cudaPackages.backendStdenv.mkDerivation {
    __structuredAttrs = true;
    strictDeps = true;

    pname = "pycuda-test";

    inherit (python.pkgs.pycuda) src version;

    nativeBuildInputs = [
      (python.withPackages (
        ps: with ps; [
          pycuda
          pytest
        ]
      ))
      cuda_nvcc
      pytestCheckHook
      writableTmpDirAsHomeHook
    ];

    buildInputs = [
      cuda_cudart
      libcurand
    ];

    prePatch = ''
      rm pycuda/__init__.py
    '';

    dontConfigure = true;
    dontBuild = true;

    postInstall = ''
      touch $out
    '';

    requiredSystemFeatures = [ "cuda" ];
  };

  meta = {
    description = "CUDA integration for Python";
    homepage = "https://github.com/inducer/pycuda/";
    license = licenses.mit;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    maintainers = with maintainers; [ connorbaker ];
    teams = [ teams.cuda ];
  };
}
