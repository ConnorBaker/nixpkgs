{
  buildPythonPackage,
  cudaPackages,
  lib,
  onnx-tensorrt, # from pkgs
  onnx,
  pycuda,
  python,
  tensorrt,
  writeShellApplication,
  writableTmpDirAsHomeHook,
  stdenvNoCC,
}:
let
  inherit (cudaPackages)
    cuda_cudart
    ;
in
buildPythonPackage {
  __structuredAttrs = true;

  inherit (onnx-tensorrt) pname version;

  src = onnx-tensorrt.dist;

  format = "wheel";

  dontUseWheelUnpack = true;

  unpackPhase = ''
    cp -rv "$src" dist
    chmod +w dist
  '';

  doCheck = false; # Tests require a GPU

  # TODO:
  # https://github.com/onnx/onnx-tensorrt/pull/1043 moved from the pycuda to cuda python package and documented it nowhere I've been able to find
  # So now I need to package the cuda python packages, at least they're only used for TensorRT 10.14.1 so I can just
  # package the newest bindings.
  dependencies = [
    (lib.getLib cuda_cudart)
    onnx
    pycuda
    tensorrt
  ];

  # TODO: pycuda tries to load libcuda.so.1 immediately.
  # pythonImportsCheck = [ "onnx_tensorrt.backend" ];

  passthru = {
    testers.onnx-tensorrt-test = writeShellApplication {
      derivationArgs = {
        __structuredAttrs = true;
        strictDeps = true;
      };
      name = "onnx-tensorrt-test";
      runtimeInputs = [
        (python.withPackages (ps: [
          ps.onnx-tensorrt
          ps.pytest
          ps.six
        ]))
        cuda_cudart
      ];
      text = ''
        echo "Creating writeable directory $HOME/.onnx"
        mkdir -p "$HOME/.onnx"
        chmod -R +w "$HOME/.onnx"

        python3 "${onnx-tensorrt.test_script}/onnx_backend_test.py" "$@"
      '';
    };

    tests =
      let
        makeTest =
          name: testArgs:
          stdenvNoCC.mkDerivation {
            __structuredAttrs = true;
            strictDeps = true;

            inherit name testArgs;

            dontUnpack = true;

            nativeBuildInputs = [
              python.pkgs.onnx-tensorrt.passthru.testers.onnx-tensorrt-test
              writableTmpDirAsHomeHook
            ];

            dontConfigure = true;

            buildPhase = ''
              nixLog "using testArgs: ''${testArgs[*]@Q}"
              onnx-tensorrt-test "''${testArgs[@]}" || {
                nixErrorLog "onnx-tensorrt-test finished with non-zero exit code: $?"
                exit 1
              }
            '';

            postInstall = ''
              touch $out
            '';

            requiredSystemFeatures = [ "cuda" ];
          };
      in
      {
        # Slow test; overlaps with realModel
        all = makeTest "short" [
          "--verbose"
        ];

        # Faster test; overlaps with all
        realModel = makeTest "real-model" [
          "--verbose"
          "OnnxBackendRealModelTest"
        ];
      };
  };

  meta = {
    # Explicitly inherit from ONNX TensorRT's meta to avoid pulling in attributes added by stdenv.mkDerivation.
    inherit (onnx-tensorrt.meta)
      description
      homepage
      license
      maintainers
      platforms
      teams
      ;
  };
}
