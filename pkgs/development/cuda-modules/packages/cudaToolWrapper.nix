{
  clippy,
  lib,
  pkgsStatic,
  rustfmt,
  tool-wrapper,
}:

let
  adapters = {
    fatbinary = "fatbinary-wrapper";
    frontend = "cuda-frontend-wrapper";
    nvlink = "nvlink-wrapper";
    nvprune = "nvprune-wrapper";
  };
in
pkgsStatic.rustPlatform.buildRustPackage {
  __structuredAttrs = true;
  name = "cuda-wrapper";
  outputs = [ "out" ] ++ builtins.attrNames adapters;

  src = lib.fileset.toSource {
    root = ../wrapper/rust;
    fileset = lib.fileset.unions [
      ../wrapper/rust/Cargo.lock
      ../wrapper/rust/Cargo.toml
      ../wrapper/rust/src
    ];
  };
  postPatch = ''
    ln -s ${tool-wrapper.src} tool-wrapper
  '';
  cargoLock.lockFile = ../wrapper/rust/Cargo.lock;
  buildFeatures = [ "wrapper" ];
  cargoBuildFlags = lib.concatMap (binary: [
    "--bin"
    binary
  ]) ([ "cuda-wrapper" ] ++ builtins.attrValues adapters);
  cargoTestFlags = [ "--lib" ];
  nativeCheckInputs = [
    clippy
    rustfmt
  ];
  postCheck = ''
    cargo fmt --check
    # Use the same musl sysroot as the build and tests.
    SYSROOT="$(rustc --print sysroot)" CARGO_BUILD_WARNINGS=deny \
      cargo clippy --locked --offline --all-features --all-targets \
        --target ${pkgsStatic.stdenv.hostPlatform.rust.rustcTargetSpec}
  '';
  postInstall = lib.concatMapAttrsStringSep "\n" (output: binary: ''
    mkdir -p "''${outputs[${output}]:?}/bin"
    mv "$out/bin/${binary}" "''${outputs[${output}]:?}/bin/"
  '') adapters;

  disallowedReferences = [ tool-wrapper.src ];

  meta = {
    description = "Rust adapters and shared runner for reproducible CUDA builds";
    mainProgram = "cuda-wrapper";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    teams = [ lib.teams.cuda ];
  };
}
