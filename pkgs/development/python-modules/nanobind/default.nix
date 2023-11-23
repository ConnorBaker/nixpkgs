{
  buildPythonPackage,
  cmake,
  eigen,
  fetchFromGitHub,
  lib,
  ninja,
  numpy,
  pytestCheckHook,
  python,
  robin-map,
  scikit-build,
  scipy,
  setuptools,
  wheel,
}:

buildPythonPackage {
  pname = "nanobind";
  version = "0-unstable-2024-01-31";
  format = "other";

  # NOTE: __structuredAttrs breaks the pytest and import check hooks.
  __contentAddressed = true;

  src = fetchFromGitHub {
    owner = "wjakob";
    repo = "nanobind";
    # Use HEAD until there's a tag that includes https://github.com/wjakob/nanobind/pull/356
    rev = "4e3a86e046a20d30a3a9fdd086dfc0cb145afe52";
    hash = "sha256-ITnnCF13TzWfLV4f7+shcxF5Ql1v3DgBF8Q5v27YCnU=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    scikit-build
    setuptools
    wheel
  ];

  buildInputs = [ robin-map ];

  cmakeFlags = [
    (lib.cmakeBool "NB_USE_SUBMODULE_DEPS" false)
    (lib.cmakeBool "NB_TEST" true)
    (lib.cmakeBool "NB_TEST_STABLE_ABI" true)
    (lib.cmakeBool "NB_TEST_SHARED_BUILD" true)
  ];

  postInstall = ''
    mkdir -p "$out/${python.sitePackages}/nanobind/"
    install -Dm755 ../src/*.py "$out/${python.sitePackages}/nanobind/"
  '';

  nativeCheckInputs = [ pytestCheckHook ];

  checkInputs = [
    eigen
    numpy
    scipy
  ];

  pythonImportsCheck = [ "nanobind" ];

  meta = with lib; {
    description = "Nanobind: tiny and efficient C++/Python bindings";
    homepage = "https://github.com/wjakob/nanobind";
    license = licenses.bsd3;
    maintainers = with maintainers; [ SomeoneSerge ];
  };
}
