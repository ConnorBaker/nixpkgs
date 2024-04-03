{
  drv,
  lib,
}:
let
  # NOTE: Don't quote src variable interpolation so we can do shell expansion.
  # NOTE: Use reflink=auto to avoid copying the files if reflinks are supported.
  cpReflinkAutoCopy = src: dst: ''
    cp \
      --archive \
      --reflink=auto \
      ${src} \
      "${dst}"
  '';
in
rec {
  unpacked = drv.overrideAttrs {
    pname = "${drv.pname}-unpacked";

    outputs = [ "out" ];

    # Move the files in postUnpack to avoid messing with unpackPhase.
    postUnpack = ''
      mv "$sourceRoot" "source"
      sourceRoot="source"
    '';

    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;

    # Copy the files to the output.
    preInstall = "";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      echo "Copying $NIX_BUILD_TOP/$sourceRoot to $out"
      ${cpReflinkAutoCopy "$NIX_BUILD_TOP/$sourceRoot/*" "$out"}
      runHook postInstall
    '';
    postInstall = "";

    dontFixup = true;

    # We use passthru.future to specify attributes used in some next stage of the build.
    passthru.future.patched = {
      # NOTE: Using the same sourceRoot throughout lets us avoid patching CMake files to change references to the source
      # directory to the build directory. We would otherwise have to do this for every stage.
      sourceRoot = "source";
      preUnpack = "";
      unpackPhase =
        ''
          runHook preUnpack
        ''
        # Unpack the source.
        + ''
          mkdir -p "$sourceRoot"
          echo "Copying source from $src to $sourceRoot"
          ${cpReflinkAutoCopy "$src/*" "$sourceRoot"}
        ''
        # Copied from pkgs/stdenv/generic/setup.sh's implementation of unpackPhase
        + ''
          # By default, add write permission to the sources.  This is often
          # necessary when sources have been copied from other store
          # locations.
          if [ "''${dontMakeSourcesWritable:-0}" != 1 ]; then
              chmod -R u+w -- "$sourceRoot"
          fi
        ''
        + ''
          runHook postUnpack
        '';
      postUnpack = "";
    };
  };

  patched = unpacked.overrideAttrs (
    {
      pname = "${drv.pname}-patched";

      src = unpacked;

      dontPatch = false;

      passthru.future.configured = {
        # Having already patched the source, we want to avoid patching it again with this derivation's specific
        # patches. We do this by setting the patchPhase attributes to the empty string.
        # NOTE: We don't want to disable the patchPhase entirely, as we still want to run any hooks which have been added
        # to that phase.
        prePatch = "";
        patchPhase = "";
        postPatch = "";
      };
    }
    // unpacked.future.patched or { }
  );

  configured = patched.overrideAttrs (
    prevAttrs:
    {
      pname = "${drv.pname}-configured";

      src = patched;

      dontConfigure = false;

      passthru.future = {
        built = {
          enableParallelBuilding = true;
          enableParallelInstalling = true;
          preConfigure = "";
          # NOTE: Without CMake's configurePhase, we must enter the build directory manually.
          configurePhase = "cd build";
          postConfigure = "";
        };
        installed = {
          # TODO:
          # magma> -- Installing: /nix/store/67y0j8i5snha59j0xq1dcv9iw6l0bmz5-magma-configured-2.7.2/lib/libmagma.so
          # magma> CMake Error at cmake_install.cmake:52 (file):
          # magma>   file INSTALL cannot copy file "/build/source/build/lib/libmagma.so" to
          # magma>   "/nix/store/67y0j8i5snha59j0xq1dcv9iw6l0bmz5-magma-configured-2.7.2/lib/libmagma.so":
          # magma>   Permission denied.
          # We must either patch the files so they point to the correct outputs, or find a way to provide the configure
          # stage of the build with the paths they will be installed to, ahead of time!

          # Patch the files so the installation doesn't happen to the destination specified by the configured build.
          postPatch = ''
            for file in $(grep -rlI "${configured}" .); do
              echo "Replacing reference to ${configured} with $out in $file"
              sed -i "s|${configured}|$out|g" "$file"
            done
          '';
        };
      };
    }
    # NOTE: We only need to override with the future attributes for the current stage, as the overrides from the
    # previous stage are propagated by way of our repeatedly calling overrideAttrs.
    // unpacked.future.configured or { }
    // patched.future.configured or { }
  );

  built = configured.overrideAttrs (
    {
      pname = "${drv.pname}-built";

      src = configured;

      dontBuild = false;

      passthru.future.installed = {
        preBuild = "";
        buildPhase = "";
        postBuild = "";
      };
    }
    // unpacked.future.built or { }
    // patched.future.built or { }
    // configured.future.built or { }
  );

  installed = built.overrideAttrs (
    {
      # Use the original pname and outputs.
      inherit (drv) pname outputs;

      src = built;

      # Use the original installPhase.
      preInstall = drv.preInstall or "";
      installPhase = drv.preInstall or "";
      postInstall = drv.postInstall or "";

      # Run the fixup phase.
      dontFixup = false;
    }
    // unpacked.future.installed or { }
    // patched.future.installed or { }
    // configured.future.installed or { }
    // built.future.installed or { }
  );
}
