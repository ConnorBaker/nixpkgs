{
  symlinkJoin,
  writeTextFile,
  runCommandLocal,
  testers,
}:

let
  inherit (testers)
    testEqualContents
    testBuildFailure
    shellcheck
    shfmt
    ;

  symlinkJoinScriptSrc = ../symlinkJoin.bash;
  evaluationFails = drv: !(builtins.tryEval drv.drvPath).success;
  invalidSymlinkJoin =
    args:
    symlinkJoin (
      {
        name = "invalid-symlink-join";
        paths = [ ];
      }
      // args
    );

  foo = writeTextFile {
    name = "foo";
    text = "foo";
    destination = "/etc/test.d/foo";
  };

  bar = writeTextFile {
    name = "bar";
    text = "bar";
    destination = "/etc/test.d/bar";
  };

  baz = writeTextFile {
    name = "baz";
    text = "baz";
    destination = "/var/lib/arbitrary/baz";
  };

  qux = writeTextFile {
    name = "qux";
    text = "qux";
  };

  collisionFile =
    name: destination:
    writeTextFile {
      inherit name destination;
      text = "${name}-content";
    };

  collideA = collisionFile "collideA" "/etc/collide/file";
  collideB = collisionFile "collideB" "/etc/collide/file";
  collideC = collisionFile "collideC" "/etc/collide2/file";
  collideD = collisionFile "collideD" "/etc/collide2/file";

  defaultStrategyPaths = [
    "nix-support/propagated-build-build-deps"
    "nix-support/propagated-native-build-inputs"
    "nix-support/propagated-build-target-deps"
    "nix-support/propagated-host-host-deps"
    "nix-support/propagated-build-inputs"
    "nix-support/propagated-target-target-deps"
    "nix-support/propagated-user-env-packages"
    "nix-support/setup-hook"
  ];

  defaultStrategyFixture =
    token:
    runCommandLocal "symlinkJoin-default-strategy-${token}" { } ''
      mkdir -p $out/nix-support
      for path in ${builtins.concatStringsSep " " defaultStrategyPaths}; do
        printf '%s:%s' '${token}' "$path" > "$out/$path"
      done
    '';

  defaultStrategyA = defaultStrategyFixture "A";
  defaultStrategyB = defaultStrategyFixture "B";

  metadataA = runCommandLocal "metadata-a" { } ''
    mkdir -p $out/{bin,etc/collide}
    printf '#!/bin/sh\necho a\n' > $out/bin/merged
    printf '#!/bin/sh\necho identical\n' > $out/bin/identical
    printf first > $out/etc/collide/file
    chmod +x $out/bin/merged
  '';

  metadataB = runCommandLocal "metadata-b" { } ''
    mkdir -p $out/{bin,etc/collide}
    printf '#!/bin/sh\necho b\n' > $out/bin/merged
    printf '#!/bin/sh\necho identical\n' > $out/bin/identical
    printf second > $out/etc/collide/file
    chmod +x $out/bin/{merged,identical} $out/etc/collide/file
  '';

  symlinkToDir = runCommandLocal "symlink-to-dir" { } ''
    mkdir -p $out/{.git,other}
    printf content > $out/other/thing
    ln -s other $out/shared
    ln -s missing $out/dangling
    touch $out/.git/config $out/backup~
  '';

  realDir = runCommandLocal "real-dir" { } ''
    mkdir -p $out/shared
    echo content2 > $out/shared/otherthing
  '';

  symlinkTargetOverride = runCommandLocal "symlink-target-override" { } ''
    mkdir -p $out/other
    printf override > $out/other/thing
    ln -s ./other $out/shared
  '';

  largeTree = runCommandLocal "symlinkJoin-large-tree-input" { } ''
    mkdir -p $out/share/files
    for index in $(seq -w 1 1000); do
      printf '%s' "$index" > "$out/share/files/$index"
    done
  '';

  emulatedSymlinkJoinFooBarStrip = runCommandLocal "symlinkJoin-strip-foo-bar" { } ''
    mkdir $out
    ln -s ${foo}/etc/test.d/foo $out/
    ln -s ${bar}/etc/test.d/bar $out/
  '';

  checkJoin =
    name: args: check:
    runCommandLocal name
      {
        joined = symlinkJoin ({ inherit name; } // args);
      }
      ''
        ${check}
        touch $out
      '';

  failedJoin = name: args: testBuildFailure (symlinkJoin ({ inherit name; } // args));

  failedStripJoin =
    name: path:
    failedJoin name {
      paths = [
        foo
        bar
        path
      ];
      stripPrefix = "/etc/test.d";
      failOnMissing = true;
    };

  failedStrategyJoin =
    name: strategy:
    failedJoin "symlinkJoin-strategy-${name}" {
      paths = [
        collideA
        collideB
      ];
      strategies.testStrategy = strategy;
      pathStrategies."etc/collide/file" = "testStrategy";
    };
in
{
  symlinkJoin = testEqualContents {
    assertion = "symlinkJoin";
    actual = symlinkJoin {
      name = "symlinkJoin";
      paths = [
        foo
        bar
        baz
      ];
    };
    expected = runCommandLocal "symlinkJoin-foo-bar-baz" { } ''
      mkdir -p $out/{var/lib/arbitrary,etc/test.d}
      ln -s {${foo},${bar}}/etc/test.d/* $out/etc/test.d
      ln -s ${baz}/var/lib/arbitrary/baz $out/var/lib/arbitrary/
    '';
  };

  symlinkJoin-strip-paths = testEqualContents {
    assertion = "symlinkJoin-strip-paths";
    actual = symlinkJoin {
      name = "symlinkJoinPrefix";
      paths = [
        foo
        bar
        baz
        qux
      ];
      stripPrefix = "/etc/test.d";
    };
    expected = emulatedSymlinkJoinFooBarStrip;
  };

  symlinkJoin-fails-on-missing =
    runCommandLocal "symlinkJoin-fails-on-missing"
      {
        missing = failedStripJoin "symlinkJoin-missing" baz;
        file = failedStripJoin "symlinkJoin-file" qux;
      }
      ''
        grep -e "-baz/etc/test.d' is not a directory" $missing/testBuildFailure.log
        grep -e "-qux/etc/test.d' is not a directory" $file/testBuildFailure.log
        touch $out
      '';

  # Every propagation/setup-hook path written by setup.sh has an explicit default strategy.
  symlinkJoin-default-strategies =
    checkJoin "symlinkJoin-default-strategies"
      {
        paths = [
          [ defaultStrategyA ]
          null
          [
            [
              defaultStrategyA
              defaultStrategyB
            ]
          ]
          largeTree
        ];
      }
      ''
        for path in ${builtins.concatStringsSep " " defaultStrategyPaths}; do
          [ "$(cat "$joined/$path")" = "$(printf 'A:%s\nB:%s' "$path" "$path")" ]
        done
        [ "$(find "$joined/share/files" -type l | wc -l)" -eq 1000 ]
        [ "$(cat "$joined/share/files/0500")" = 0500 ]
      '';

  # Prefixes use the most specific match, and caller maps do not replace the defaults.
  symlinkJoin-collision-prefix-strategy =
    checkJoin "symlinkJoin-collision-prefix-strategy"
      {
        paths = [
          defaultStrategyA
          defaultStrategyB
          collideA
          collideB
          collideC
          collideD
        ];
        strategies = {
          concatenateWithNewline = ''
            cat -- "$mergeExisting" > "$mergeOut"
            printf '\n' >> "$mergeOut"
            cat -- "$mergeNew" >> "$mergeOut"
          '';
          concatWithSeparator = ''
            cat -- "$mergeExisting" > "$mergeOut"
            printf '|' >> "$mergeOut"
            cat -- "$mergeNew" >> "$mergeOut"
          '';
        };
        pathStrategies = {
          "etc" = "concatWithSeparator";
          "etc/collide/file" = "concatenateWithNewline";
        };
        postBuild = ''
          grep -q A:nix-support/setup-hook "$out/nix-support/setup-hook"
          touch "$out/postbuild-marker"
        '';
      }
      ''
        [ "$(cat "$joined/nix-support/setup-hook")" = "$(printf 'A:nix-support/setup-hook\nB:nix-support/setup-hook')" ]
        [ "$(cat "$joined/etc/collide/file")" = "$(printf 'collideA-content\ncollideB-content')" ]
        [ "$(cat "$joined/etc/collide2/file")" = "collideC-content|collideD-content" ]
        [ -e "$joined/postbuild-marker" ]
      '';

  # Cover metadata for merged, byte-identical, and explicitly retained entries in one join.
  symlinkJoin-collision-metadata =
    checkJoin "symlinkJoin-collision-metadata"
      {
        paths = [
          metadataA
          metadataA
          metadataB
        ];
        pathStrategies."bin/merged" = "concatenateWithNewline";
        pathStrategies."etc/collide/file" = "keepExisting";
      }
      ''
        [ -x "$joined/bin/merged" ]
        [ -x "$joined/bin/identical" ]
        [ "$(cat "$joined/bin/identical")" = "$(cat ${metadataB}/bin/identical)" ]
        [ "$(cat "$joined/etc/collide/file")" = first ]
        [ "$(readlink "$joined/etc/collide/file")" = "${metadataA}/etc/collide/file" ]
        [ ! -x "$joined/etc/collide/file" ]
      '';

  # Source symlinks retain their link text; lndir's VCS and backup exclusions remain intact.
  symlinkJoin-preserves-relative-symlinks =
    checkJoin "symlinkJoin-preserves-relative-symlinks"
      {
        paths = [
          symlinkToDir
          symlinkToDir
          symlinkTargetOverride
        ];
        pathStrategies."other/thing" = "concatenateWithNewline";
        pathStrategies."shared" = "keepExisting";
      }
      ''
        [ "$(readlink "$joined/shared")" = "other" ]
        [ "$(readlink "$joined/dangling")" = "missing" ]
        [ "$(cat "$joined/shared/thing")" = "$(printf 'content\noverride')" ]
        [ ! -e "$joined/.git" ]
        [ ! -e "$joined/backup~" ]
      '';

  symlinkJoin-collision-failures =
    runCommandLocal "symlinkJoin-collision-failures"
      {
        directoryConflict = failedJoin "symlinkJoin-symlink-to-dir" {
          paths = [
            symlinkToDir
            realDir
          ];
        };
        failedCommand = failedStrategyJoin "failed-command" "false";
        directoryOutput = failedStrategyJoin "directory-output" ''
          mkdir "$mergeOut"
        '';
        symlinkOutput = failedStrategyJoin "symlink-output" ''
          ln -s -- "$mergeNew" "$mergeOut"
        '';
        unhandled = failedJoin "symlinkJoin-multi-collision" {
          paths = [
            collideA
            collideB
            collideC
            collideD
          ];
        };
      }
      ''
        grep -F "'shared' is a directory there, but a non-directory was already placed at" \
          $directoryConflict/testBuildFailure.log
        grep -F "strategy 'testStrategy' failed while merging 'etc/collide/file'" \
          $failedCommand/testBuildFailure.log
        grep -F "strategy 'testStrategy' did not produce a regular file" \
          $directoryOutput/testBuildFailure.log
        grep -F "strategy 'testStrategy' did not produce a regular file" \
          $symlinkOutput/testBuildFailure.log
        grep -F "'etc/collide/file' collides with content already placed at" \
          $unhandled/testBuildFailure.log
        grep -F "'etc/collide2/file' collides with content already placed at" \
          $unhandled/testBuildFailure.log
        grep -F "no merge strategy is registered for 'etc/collide/file'" \
          $unhandled/testBuildFailure.log
        touch $out
      '';

  # Invalid strategy maps fail during evaluation.
  symlinkJoin-invalid-configuration-evaluation-fails =
    assert builtins.all (args: evaluationFails (invalidSymlinkJoin args)) [
      { __structuredAttrs = false; }
      { failOnMissing = "yes"; }
      { strategies = [ ]; }
      { pathStrategies = [ ]; }
      { strategies.notAString = 1; }
      { strategies."" = ":"; }
      { pathStrategies."etc/collide" = 1; }
      { pathStrategies."etc//collide" = "keepExisting"; }
      { pathStrategies."etc/collide" = "notRegistered"; }
    ];
    runCommandLocal "symlinkJoin-invalid-configuration-evaluation-fails" { } ''
      touch $out
    '';

  # Calling the private lookup helper with the wrong arity is an internal programming error.
  # It must terminate immediately, never return a status that callers could mistake for a
  # legitimate "no matching prefix" result.
  symlinkJoin-lookup-incorrect-arity-fails =
    runCommandLocal "symlinkJoin-lookup-incorrect-arity-fails"
      {
        failed = testBuildFailure (
          runCommandLocal "symlinkJoin-lookup-incorrect-arity" { } ''
            source ${symlinkJoinScriptSrc}
            declare -A lookupTable=()
            if __symlinkJoinLookupByPrefix "some/path" lookupTable; then
              echo "unexpected lookup success"
            fi
            touch $out
          ''
        );
      }
      ''
        grep -F \
          "internal error: __symlinkJoinLookupByPrefix requires path, table, and output variable" \
          $failed/testBuildFailure.log
        touch $out
      '';

  symlinkJoinScript-shellcheck = shellcheck {
    name = "symlinkJoin-script";
    src = symlinkJoinScriptSrc;
  };

  symlinkJoinScript-shfmt = shfmt {
    name = "symlinkJoin-script";
    src = symlinkJoinScriptSrc;
  };
}
