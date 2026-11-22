{
  backendStdenv,
  cccl,
  cuda_crt,
  cuda_cudart,
  cuda_cuobjdump,
  cuda_nvcc,
  cudaAtLeast,
  cudaOlder,
  flags,
  lib,
  libcurand,
  llvmPackages,
  python3,
  runCommand,
  testers,
}:
# Tests for the nvcc and nvlink wrappers; see README.md.
let
  # nvlink records its command line from CUDA 12.8 for some architectures, including sm_100, and from CUDA 13 for all.
  # The tests link programs without running them, so they use one of those architectures.
  recordsCommandLine = cudaAtLeast "12.8";
  arch = if recordsCommandLine then "sm_100" else lib.head flags.realArches;

  cudadevrtDir = "${lib.getOutput "static" cuda_cudart}/lib";

  # Whether the nvcc wrapper passes --frandom-seed. nvcc has that option from CUDA 12.9.
  seeds = cudaAtLeast "12.9";

  helpers = ''
    # Prints the command line recorded in each note written by nvlink.
    nvlinkOptions() {
      cuobjdump -elf "$1" \
        | awk '/Tool Name:/ { nvlink = ($3 == "nvlink") } nvlink && /Arguments:/ { sub(/.*Arguments: /, ""); print; nvlink = 0 }'
    }

    # Fails if a note in the file refers to the Nix store (by the hash of a store path, as Nix finds references), or if
    # nvlink wrote no note where it should have.
    checkNotes() {
      if cuobjdump -elf "$1" | grep -E 'Tool [A-Za-z ]+: .*[0-9a-df-np-sv-z]{32}'; then
        nixErrorLog "a note in $1 refers to the Nix store"
        exit 1
      fi
      local options
      options="$(nvlinkOptions "$1")"
      if [[ -z $options ]] && ${lib.boolToString recordsCommandLine}; then
        nixErrorLog "found no note from nvlink in $1"
        exit 1
      fi
      nixLog "nvlink recorded in $1: $options"
    }

    # Runs a command which must fail with the wrapper's error, message, and remove the output, result.
    expectFailure() {
      local message="$1"
      shift
      if "$@" 2> stderr.txt; then
        nixErrorLog "expected $* to fail"
        exit 1
      fi
      cat stderr.txt
      grep -F "nvlink wrapper: error: $message" stderr.txt
      if [[ -e result ]]; then
        nixErrorLog "expected the output to be removed"
        exit 1
      fi
    }
  '';

  mkTest =
    name: script:
    backendStdenv.mkDerivation {
      __structuredAttrs = true;
      strictDeps = true;

      name = "${cuda_nvcc.name}-${name}";

      inherit arch;

      nativeBuildInputs = [
        cuda_cuobjdump
        cuda_nvcc
      ];

      buildInputs = [ cuda_cudart ];

      dontUnpack = true;
      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        cp ${./tests/kernel.cu} kernel.cu
        cp ${./tests/caller.cu} caller.cu
        cp ${./tests/answer.cu} answer.cu
        cp ${./tests/templates.cu} templates.cu
        cp ${./gpu-check.cu} gpu-check.cu
      ''
      + helpers
      + script
      + ''
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        [[ ! -e result ]] || cp -v result "$out/"
        runHook postInstall
      '';

      # The directories nvlink records must not become runtime dependencies. (Nix doesn't find references in compressed
      # fatbins, e.g. with -Xfatbin -compress-all, so checkNotes is what checks those.)
      disallowedRequisites = [ cuda_nvcc ] ++ map (output: cuda_cudart.${output}) cuda_cudart.outputs;

      meta = {
        inherit (cuda_nvcc.meta) badPlatforms platforms teams;
      };
    };
in
{
  # nvcc writes the same objects and programs when it runs again.
  nvcc-reproducible = mkTest "nvcc-reproducible" ''
    # Runs a command twice and compares the two outputs.
    twice() {
      local output="$1"
      shift
      "$@" -o "$output"
      mv "$output" first
      "$@" -o "$output"
      if ! cmp first "$output"; then
        nixErrorLog "$* wrote a different $output the second time"
        exit 1
      fi
    }
    twice kernel.o nvcc -arch="$arch" -c kernel.cu
    twice debug.o nvcc -arch="$arch" -g -c kernel.cu
    twice relocatable.o nvcc -arch="$arch" -rdc=true -c caller.cu
    # CMake compiles sources that are not named *.cu in this way.
    cp kernel.cu kernel.cpp
    twice language.o nvcc -arch="$arch" -x cu -c kernel.cpp
    cp ${if seeds then "templates.cu" else "kernel.cu"} kernel-no-extension
    twice extensionless.o nvcc -arch="$arch" -x cu -c kernel-no-extension
    mkdir pre-include
    printf '%s\n' '#define PRE_INCLUDED 1' > pre-include/kernel.cu
    twice pre-include.o nvcc -arch="$arch" -include pre-include/kernel.cu -c kernel.cu
    cp kernel.cu "source with spaces.cu"
    printf '%s\n' "-arch=$arch -g -c \"source with spaces.cu\"" > nvcc.optf
    twice options.o nvcc -optf nvcc.optf
    # Without -c, the objects are intermediate files as well.
    twice result nvcc -arch="$arch" kernel.cu
    ${lib.optionalString seeds ''twice templates.o nvcc -arch="$arch" -c templates.cu''}

    # Without --keep, nvcc names its intermediate files tmpxft_<pid>_...
    if grep --text --fixed-strings tmpxft ./*.o result; then
      nixErrorLog "an output contains the name of a temporary file"
      exit 1
    fi

    # nvcc without the wrapper must still write different objects. If it does not, the wrapper is no longer needed.
    for source in kernel.cu ${lib.optionalString seeds "templates.cu"}; do
      (exec -a nvcc ${cuda_nvcc}/bin/.nvcc-wrapped -arch="$arch" -c "$source" -o unwrapped-1.o)
      (exec -a nvcc ${cuda_nvcc}/bin/.nvcc-wrapped -arch="$arch" --keep --keep-dir "$(mktemp -d)" -c "$source" \
        -o unwrapped-2.o)
      (exec -a nvcc ${cuda_nvcc}/bin/.nvcc-wrapped -arch="$arch" --keep --keep-dir "$(mktemp -d)" -c "$source" \
        -o unwrapped-3.o)
      if cmp --silent unwrapped-1.o unwrapped-2.o; then
        nixErrorLog "expected nvcc to name the object of $source after a temporary file"
        exit 1
      fi
      if ${lib.boolToString seeds} && [[ $source == templates.cu ]] && cmp --silent unwrapped-2.o unwrapped-3.o; then
        nixErrorLog "expected nvcc to name the symbols of $source after its process ID"
        exit 1
      fi
    done

    # The wrapper removes the directory in which nvcc kept the intermediate files.
    if [[ -n $(find "$TMPDIR" -maxdepth 1 -name 'nvcc-keep-*') ]]; then
      nixErrorLog "the wrapper left a directory in $TMPDIR"
      exit 1
    fi
  '';

  # The cases in which the wrapper does not override the caller.
  nvcc-wrapper = mkTest "nvcc-wrapper" ''
    # Two sources with the same name cannot share a directory for their intermediate files. Without -c, their objects
    # are in that directory too.
    mkdir a b
    echo 'int a() { return 1; }' > a/same.cu
    echo 'int a(); int main() { return a(); }' > b/same.cu
    nvcc -arch="$arch" a/same.cu b/same.cu -o result

    # nvcc uses the directory that the caller passes, and the wrapper does not remove it. CMake depends on this when
    # it identifies nvcc.
    mkdir kept
    nvcc -arch="$arch" --keep --keep-dir kept -c kernel.cu -o kernel.o
    [[ -e kept/kernel.ptx ]]
    nvcc -arch="$arch" -rdc=true --keep -c caller.cu -o caller.o
    [[ -e caller.ptx ]]
    rm caller.ptx
    NVCC_APPEND_FLAGS=$'-O2\t--keep' nvcc -arch="$arch" -rdc=true -c caller.cu -o caller.o
    [[ -e caller.ptx ]]
    NVCC_APPEND_FLAGS="--keep --keep-dir=kept" nvcc -arch="$arch" -c answer.cu -o answer.o
    [[ -e kept/answer.ptx ]]
    printf '%s\n' "-arch=$arch --keep --keep-dir=kept -c \"options source.cu\"" > nvcc.optf
    cp kernel.cu "options source.cu"
    nvcc --options-file=nvcc.optf -o options.o
    [[ -e "kept/options source.ptx" ]]
    ${lib.optionalString seeds ''
      # nvcc uses the seed that the caller passes.
      nvcc -arch="$arch" --frandom-seed=1 -c templates.cu -o seed-1.o
      nvcc -arch="$arch" --frandom-seed=2 -c templates.cu -o seed-2.o
      NVCC_PREPEND_FLAGS=--frandom-seed=1 nvcc -arch="$arch" -c templates.cu -o seed-3.o
      if cmp --silent seed-1.o seed-2.o || ! cmp seed-1.o seed-3.o; then
        nixErrorLog "expected the seed passed to nvcc to be used"
        exit 1
      fi
    ''}

    # The wrapper exits with the status of nvcc, and removes the directory when nvcc fails too.
    echo 'syntax error' > broken.cu
    expected=0
    (exec -a nvcc ${cuda_nvcc}/bin/.nvcc-wrapped -arch="$arch" -c broken.cu -o broken.o) || expected=$?
    status=0
    nvcc -arch="$arch" -c broken.cu -o broken.o || status=$?
    if [[ $expected == 0 || $status != "$expected" ]]; then
      nixErrorLog "expected nvcc to exit with its status ($expected), got $status"
      exit 1
    fi

    # A configure check can pass an output that is not in a writable directory.
    nvcc -arch="$arch" -c kernel.cu -o /dev/null

    nvcc --version
    nvcc -arch="$arch" -E kernel.cu > /dev/null

    # The vendor driver needs to find the installed profile even through an external symlink.
    mkdir linked
    ln -s ${cuda_nvcc}/bin/nvcc linked/nvcc
    env -i TMPDIR="$TMPDIR" ./linked/nvcc -arch="$arch" --ptx kernel.cu -o linked.ptx

    if [[ -n $(find "$TMPDIR" -maxdepth 1 -name 'nvcc-keep-*') ]]; then
      nixErrorLog "the wrapper left a directory in $TMPDIR"
      exit 1
    fi
  '';

  nvcc-process =
    runCommand "${cuda_nvcc.name}-nvcc-process"
      {
        meta = { inherit (cuda_nvcc.meta) badPlatforms platforms teams; };
      }
      ''
        ${python3}/bin/python3 -P ${./tests/nvcc-process.py} ${cuda_nvcc.nvccWrapper}/bin/nvcc-wrapper
        touch "$out"
      '';

  ptxas-process =
    runCommand "${cuda_nvcc.name}-ptxas-process"
      {
        meta = { inherit (cuda_nvcc.meta) badPlatforms platforms teams; };
      }
      ''
        cp ${cuda_nvcc.ptxasWrapper}/bin/ptxas-wrapper ptxas
        cat > .ptxas-wrapped <<'EOF'
        #!${python3}/bin/python3
        import os
        import sys

        if os.path.lexists("/proc/self/fd/0"):
            sys.exit("the wrapper reopened stdin")
        with open(sys.argv[1], "rb") as source:
            if b'"/mapped/source.cu"' not in source.read():
                sys.exit("the vendor did not receive the rewritten PTX")
        EOF
        chmod +x .ptxas-wrapped
        printf '.version 8.0\n.file 1 "%s/source.cu"\n' "$PWD" > input.ptx
        BUILD_PATH_PREFIX_MAP="/mapped=$PWD" ./ptxas input.ptx <&-
        touch "$out"
      '';

  nvcc-ptx-source-paths = mkTest "nvcc-ptx-source-paths" ''
    mkdir 'source tree' outputs
    cp kernel.cu 'source tree/kernel.cu'
    cp kernel.cu 'source tree/second.cu'
    export BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD/source tree"

    # With -odir, nvcc writes one PTX file per input in the named directory.
    printf '%s\n' '--ptx -lineinfo -odir outputs "source tree/kernel.cu" "source tree/second.cu"' > compile.optf
    nvcc -arch=sm_80 --options-file=compile.optf
    for file in kernel second; do
      grep -F "\"/usr/src/cuda-test/$file.cu\"" "outputs/$file.ptx"
      if grep -F "$PWD/source tree/" "outputs/$file.ptx"; then
        nixErrorLog "nvcc retained a remapped source path in standalone PTX"
        exit 1
      fi
    done
    ptxas -arch=sm_80 -o shortened.cubin outputs/kernel.ptx

    nvcc -arch=sm_80 --ptx -lineinfo 'source tree/kernel.cu'
    grep -F '"/usr/src/cuda-test/kernel.cu"' kernel.ptx

    # An explicit filename overrides -odir. The replacement may grow the file.
    target="$PWD/canonical/source/tree"
    BUILD_PATH_PREFIX_MAP="$target=$PWD/source tree" nvcc -arch=sm_80 --ptx -lineinfo \
      -odir outputs -o explicit 'source tree/kernel.cu'
    grep -F "\"$target/kernel.cu\"" explicit
    ptxas -arch=sm_80 -o lengthened.cubin explicit

    # A stream still goes directly to the caller.
    nvcc -arch=sm_80 --ptx -lineinfo -o - 'source tree/kernel.cu' > streamed.ptx
    grep -F "\"$PWD/source tree/kernel.cu\"" streamed.ptx
  '';

  ptxas-lineinfo = mkTest "ptxas-lineinfo" ''
    mkdir 'source tree'
    printf '%s\n' '// device source' > 'source tree/test.cu'
    cat > input.ptx << EOF
    .version 8.0
    .target sm_80
    .address_size 64
    .file 1 "$PWD/source tree/test.cu"
    .visible .entry test() {
      .loc 1 1 0
      ret;
    }
    EOF
    printf '%s\n' '-arch=sm_80 -lineinfo "input.ptx" -o "file output.cubin"' > ptxas.optf

    # Cross a ULEB128 size boundary in the raw line table.
    for mtime in 1 1900000000; do
      touch -d "@$mtime" 'source tree/test.cu'
      BUILD_PATH_PREFIX_MAP= ptxas --options-file=ptxas.optf
      mv 'file output.cubin' "$mtime.cubin"
    done
    cmp 1.cubin 1900000000.cubin
    readelf --debug-dump=rawline 1.cubin | grep -F "$PWD/source tree"

    cp input.ptx 'input=with spaces.ptx'
    printf '%s\n' '-lineinfo "input=with spaces.ptx" -o "mapped.cubin"' > inner.optf
    printf '%s\n' '-arch=sm_80 --options-file=inner.optf' > outer.optf
    BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD/source tree" ptxas -optf outer.optf
    readelf --debug-dump=rawline mapped.cubin > mapped.txt
    grep -F /usr/src/cuda-test mapped.txt
    grep -F test.cu mapped.txt
    if grep -F "$PWD/source tree" mapped.txt; then
      nixErrorLog "ptxas retained an explicitly remapped source path"
      exit 1
    fi

    # Nonzero timestamps explicitly set by the PTX generator carry through.
    sed 's/test\.cu"$/test.cu", 12345, 42/' input.ptx > explicit.ptx
    ptxas -arch=sm_80 -lineinfo -o explicit.cubin explicit.ptx
    readelf --debug-dump=rawline explicit.cubin | grep -E '12345[[:space:]]+42[[:space:]]+test\.cu'

    # PTX allows hexadecimal and binary integer literals with an unsigned suffix.
    sed -e 's/\.file 1 /.file 0x1 /' -e 's/test\.cu"$/test.cu", 0B0U, 42/' input.ptx > zero.ptx
    ptxas -arch=sm_80 -lineinfo -o zero.cubin zero.ptx
    ${lib.optionalString (cudaOlder "13.4") ''
      readelf --debug-dump=rawline zero.cubin | grep -E '[[:space:]]1[[:space:]]+42[[:space:]]+test\.cu'
    ''}
  '';

  fatbinary-source-paths = mkTest "fatbinary-source-paths" ''
    BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD" nvcc -lineinfo \
      '-gencode=arch=compute_80,code=[sm_80,compute_80]' -c "$PWD/kernel.cu" -o fatbin.o
    cuobjdump -ptx fatbin.o > embedded.ptx
    cuobjdump -elf fatbin.o > embedded.elf
    grep -F 'identifier = /usr/src/cuda-test/kernel.cu' embedded.ptx
    grep -E '\.file[[:space:]]+[0-9]+ "/usr/src/cuda-test/kernel\.cu"' embedded.ptx
    grep -F /usr/src/cuda-test embedded.elf
    if grep -F "$PWD/kernel.cu" embedded.ptx embedded.elf; then
      nixErrorLog "fatbinary retained an explicitly remapped source path"
      exit 1
    fi

    # Linux limits the size of a single argv entry. An options file can hold a larger identifier.
    nvcc -arch=sm_80 -ptx kernel.cu -o input.ptx
    printf -v padding '%140000s' ""
    printf -- '--ident="%s/%s"\n' "$PWD" "''${padding// /x}" > identifier.optf
    printf '%s\n' '-optf identifier.optf --image3=kind=ptx,sm=80,file=input.ptx' > fatbinary.optf
    BUILD_PATH_PREFIX_MAP="/usr/src/cuda-test=$PWD" fatbinary -64 -optf fatbinary.optf --create=large.fatbin
    cuobjdump -ptx large.fatbin > large.ptx
    grep -q -F 'identifier = /usr/src/cuda-test/xxxxxxxx' large.ptx
  '';

  # nvcc runs nvlink for a whole-program link, even without -rdc.
  nvcc-whole-program = mkTest "nvcc-whole-program" ''
    nvcc -arch="$arch" kernel.cu -o result
    checkNotes result
  '';

  # The -L passed by the build is removed along with nvcc's own.
  nvcc-library-dir = mkTest "nvcc-library-dir" ''
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} -o result
    checkNotes result
  '';

  # Nix doesn't find references in a compressed fatbin, so disallowedRequisites can't catch them there; checkNotes reads
  # the notes through cuobjdump, which decompresses them.
  nvcc-compressed = mkTest "nvcc-compressed" ''
    nvcc -arch="$arch" -rdc=true -Xfatbin -compress-all caller.cu answer.cu -L${cudadevrtDir} -o result
    checkNotes result
    options="$(nvlinkOptions result)"
    if [[ -n $options ]] && grep -a -q -F -- "$options" result; then
      nixErrorLog "expected the note in result to be compressed"
      exit 1
    fi
  '';

  # The host linker copies the fatbin, and so the note, as-is.
  nvcc-static-executable =
    (mkTest "nvcc-static-executable" ''
      nvcc -arch="$arch" -rdc=true -Xcompiler -static caller.cu answer.cu -L${cudadevrtDir} -o result
      if readelf --program-headers result | grep -E 'INTERP|DYNAMIC'; then
        nixErrorLog "expected result to be a static executable"
        exit 1
      fi
      # cuobjdump doesn't find the device code in a static executable.
      objcopy --dump-section .nv_fatbin=fatbin result
      checkNotes fatbin
    '').overrideAttrs
      (prevAttrs: {
        buildInputs = prevAttrs.buildInputs ++ [ (lib.getOutput "static" backendStdenv.cc.libc) ];
      });

  # A device-link object in a static library, as from CMake's CUDA_RESOLVE_DEVICE_SYMBOLS.
  nvcc-device-link-object = mkTest "nvcc-device-link-object" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    nvcc -arch="$arch" -dlink caller.o answer.o -L${cudadevrtDir} -o dlink.o
    ar rcs result caller.o answer.o dlink.o
    checkNotes result
  '';

  # nvcc passes long command lines to nvlink in an options file, which names the output (CUDA 12.8 and newer; CUDA 12.6
  # passes them directly).
  nvcc-options-file = mkTest "nvcc-options-file" ''
    libdirs=()
    for i in $(seq 1000); do
      libdirs+=("-L$NIX_BUILD_TOP/a/directory/with/a/long/enough/name/to/make/the/command/line/long/$i")
    done
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} "''${libdirs[@]}" -o result --dryrun 2> dryrun.txt
    ${lib.optionalString recordsCommandLine "grep -F 'nvlink -optf' dryrun.txt"}
    nvcc -arch="$arch" -rdc=true caller.cu answer.cu -L${cudadevrtDir} "''${libdirs[@]}" -o result
    checkNotes result
  '';

  # The wrapper doesn't depend on setup hooks, as with nix develop or a build system outside stdenv.
  nvcc-empty-environment = mkTest "nvcc-empty-environment" ''
    env -i TMPDIR="$TMPDIR" ${lib.getExe cuda_nvcc} -arch="$arch" -rdc=true caller.cu answer.cu \
      ${
        lib.concatMapStringsSep " " (p: "-I${lib.getInclude p}/include") (
          [ cuda_cudart ] ++ lib.optionals (cudaAtLeast "13.0") [ cuda_crt ]
        )
      } \
      -L${cudadevrtDir} -o result
    checkNotes result
  '';

  # nvlink called directly, with each spelling of the output and options files.
  nvlink-output = mkTest "nvlink-output" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    link() {
      nvlink --arch="$arch" caller.o answer.o -L ${cudadevrtDir} "''${@:2}"
      checkNotes "$1"
    }
    link a -o a
    link b -o=b
    link c --output-file c
    link d --output-file=d
    link e -o ignored -o e

    # Double quotes group, a backslash escapes (dropping escaped double quotes), and options files may include others.
    printf '%s\n' '-o "f g"' > quoted.optf
    printf '%s\n' '-o h\ i' > escaped.optf
    printf '%s\n' '-o "j\"k"' > escaped-quote.optf
    printf '%s\n' '-L ${cudadevrtDir}' '-optf quoted.optf' > nested.optf
    link "f g" -optf quoted.optf
    link "h i" -optf escaped.optf
    link jk -optf escaped-quote.optf
    link "f g" --options-file=nested.optf
    link "h i" -optf nested.optf,,escaped.optf

    # Only the hashes change, to e's (octal 145): the output is otherwise the same as nvlink's.
    (exec -a nvlink ${cuda_nvcc}/bin/.nvlink-wrapped --arch="$arch" caller.o answer.o -L ${cudadevrtDir} -o unwrapped)
    [[ $(stat -c %s a) == $(stat -c %s unwrapped) ]]
    cmp -l a unwrapped > differences || true
    awk '$2 != 145 { print "unexpected difference: " $0; exit 1 }' differences
    ${lib.optionalString recordsCommandLine "[[ -s differences ]]"}

    # A host linker script is written as-is.
    nvlink -ghls lcs-abs -o wrapped.ld
    ${cuda_nvcc}/bin/.nvlink-wrapped -ghls lcs-abs -o unwrapped.ld
    cmp wrapped.ld unwrapped.ld

    nvlink --version
  '';

  # CUDA 13's nvlink keeps the notes of the cubins it links, including those of cubins linked without the wrapper, which
  # the wrapper scrubs too.
  nvlink-input-notes = mkTest "nvlink-input-notes" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    # NOTE: nvlink only links inputs named *.cubin as cubins, and before CUDA 13, a relocatable link of relocatable
    # device code requires libcudadevrt.
    (exec -a nvlink ${cuda_nvcc}/bin/.nvlink-wrapped --arch="$arch" -r caller.o answer.o -L ${cudadevrtDir} -lcudadevrt \
      -o input.cubin)
    nvlink --arch="$arch" input.cubin -L ${cudadevrtDir} -o result
    checkNotes result
    if ${lib.boolToString (cudaAtLeast "13.0")} && (( $(nvlinkOptions result | wc -l) < 2 )); then
      nixErrorLog "expected nvlink to keep the note of its input"
      exit 1
    fi
  '';

  # The wrapper reads the output back, so an output which isn't a regular file fails before nvlink runs.
  nvlink-stream-output = mkTest "nvlink-stream-output" ''
    nvcc -arch="$arch" -rdc=true -c caller.cu answer.cu
    # The wrapper would block reading back the output from the pipe.
    expectFailure "/dev/stdout is not a regular file" \
      timeout -s KILL 60 bash -c "nvlink --arch=$arch caller.o answer.o -o /dev/stdout | cat > streamed; exit \''${PIPESTATUS[0]}"
    [[ ! -s streamed ]]
  '';

  # nvlink's errors and exit status are passed through.
  nvlink-error = testers.testBuildFailure' {
    drv = mkTest "nvlink-error" ''
      nvcc -arch="$arch" -rdc=true -c caller.cu
      # Without answer.o.
      nvlink --arch="$arch" caller.o -o result
    '';
    expectedBuilderExitCode = 255;
    expectedBuilderLogEntries = [ "Undefined reference to '_Z6answerv'" ];
  };

  # The installed wrapper's handling of nvlink as a process and of its output, with a stand-in for nvlink next to it.
  wrapper =
    (mkTest "wrapper" ''
      cp ${cuda_nvcc}/bin/nvlink nvlink
      cp ${./tests/fake-nvlink} .nvlink-wrapped
      chmod +w nvlink
      chmod +x .nvlink-wrapped
      patchShebangs .nvlink-wrapped
      mkdir alone
      cp nvlink alone/nvlink
      export FAKE_LOG=$PWD/log

      status() { "$@" && echo 0 || echo $?; }
      signal() { python3 ${./tests/signal.py} "$@"; }
      expect() {
        if [[ $1 != "$2" ]]; then
          nixErrorLog "$3: expected $2, got $1"
          exit 1
        fi
      }

      # Exit statuses, arguments, and the environment are passed through.
      expect "$(FAKE=exit FAKE_STATUS=3 status ./nvlink)" 3 "nvlink's exit status"
      FAKE=exit FAKE_STATUS=0 FAKE_ENV="a b" ./nvlink "x y" ""
      # Outside the foreground of a terminal, as here, nvlink runs in a process group of its own.
      expect "$(cat log)" $'x y\n\nFAKE_ENV=a b\npid='"$(sed -n 's/^pid=//p' log)"$'\ngroup=own' \
        "nvlink's arguments, environment, and process group"
      FAKE=exit FAKE_STATUS=0 ./nvlink -L -o
      FAKE=exit FAKE_STATUS=0 ./nvlink -L -optf
      FAKE=exit FAKE_STATUS=0 ./nvlink -o unused --version
      [[ ! -e unused ]]
      expect "$(status ./alone/nvlink)" 127 "the exit status without .nvlink-wrapped next to the wrapper"
      # The wrapper finds nvlink next to itself rather than to the link it was run through.
      mkdir linked
      ln -s ../nvlink linked/nvlink
      expect "$(FAKE=exit FAKE_STATUS=4 status ./linked/nvlink)" 4 "nvlink's exit status through a symbolic link"
      # The wrapper forwards SIGTERM rather than exiting, so the timeout kills it.
      ignoringSigchld='import os, signal, sys; signal.signal(signal.SIGCHLD, signal.SIG_IGN); os.execv(sys.argv[1], sys.argv[1:])'
      expect "$(FAKE=exit FAKE_STATUS=3 status timeout -s KILL 60 python3 -c "$ignoringSigchld" ./nvlink)" 3 \
        "nvlink's exit status with SIGCHLD ignored, which is inherited"

      # If nvlink is killed by a signal, so is the wrapper.
      expect "$(FAKE=kill FAKE_SIGNAL=TERM signal none - ./nvlink)" -15 "how the wrapper exits when nvlink is killed"

      # Signals sent to the wrapper, or to its process group, are forwarded to nvlink once.
      for sig in HUP INT QUIT TERM USR1 USR2 group:TERM group:USR1; do
        rm -f log*
        expect "$(FAKE="wait" signal "$sig" log.ready ./nvlink)" 0 "the exit status after $sig"
        expect "$(grep -c "received ''${sig#group:}" log)" 1 "$sig received by nvlink"
      done
      # In the foreground of a terminal, nvlink shares the wrapper's process group, so signals from the terminal reach
      # it directly, and aren't forwarded.
      rm -f log*
      expect "$(FAKE="wait" signal ctrl-c log.ready ./nvlink)" 0 "the exit status after Ctrl-C"
      expect "$(grep -c "received INT" log)" 1 "SIGINT received by nvlink after Ctrl-C"
      expect "$(sed -n 's/^group=//p' log)" shared "nvlink's process group in the foreground of a terminal"
      rm -f log*
      expect "$(FAKE=detached signal ctrl-c log.ready ./nvlink)" 0 "the exit status after Ctrl-C"
      expect "$(grep -c "received INT" log || true)" 0 "SIGINT forwarded to nvlink after Ctrl-C"

      # nvlink doesn't outlive the wrapper.
      rm -f log*
      expect "$(FAKE="sleep" signal KILL log.ready ./nvlink)" -9 "how the wrapper exits when killed"
      for _ in $(seq 50); do
        kill -0 "$(sed -n 's/^pid=//p' log)" 2> /dev/null || break
        sleep 0.1
      done
      if kill -0 "$(sed -n 's/^pid=//p' log)" 2> /dev/null; then
        nixErrorLog "nvlink outlived the wrapper"
        exit 1
      fi

      # Hashes of store paths are blanked in .note.nv.tkinfo sections, and only there.
      hash=0123456789abcdfghijklmnpqrsvwxyz
      printf 'nvlink\0-L ${builtins.storeDir}/%s-x/lib\0' "$hash" > note
      echo 'int x;' | "$CC" -c -x c - -o empty.o
      objcopy --add-section .note.nv.tkinfo=note --add-section .other=note empty.o note.o
      FAKE=write FAKE_CONTENTS=note.o ./nvlink -o scrubbed.o
      objcopy --dump-section .note.nv.tkinfo=scrubbed --dump-section .other=other scrubbed.o
      sed "s/$hash/$(printf 'e%.0s' {1..32})/" note > expected
      cmp scrubbed expected
      cmp other note
      # With many sections, the number of sections and the index of the section names are in the first section header.
      python3 -c '
      import struct, sys
      elf = bytearray(open(sys.argv[1], "rb").read())
      (shoff,) = struct.unpack_from("<Q", elf, 0x28)
      shnum, shstrndx = struct.unpack_from("<HH", elf, 0x3C)
      struct.pack_into("<HH", elf, 0x3C, 0, 0xFFFF)  # e_shnum, e_shstrndx (SHN_XINDEX)
      struct.pack_into("<Q", elf, shoff + 0x20, shnum)  # sh_size
      struct.pack_into("<I", elf, shoff + 0x28, shstrndx)  # sh_link
      open(sys.argv[2], "wb").write(elf)
      ' note.o extended.o
      readelf --file-header extended.o | grep -F 'Number of section headers:         0 ('
      FAKE=write FAKE_CONTENTS=extended.o ./nvlink -o scrubbed-extended.o
      expect "$(grep -a -o -F "$hash" scrubbed-extended.o | wc -l)" 1 "hashes left in a file with many sections"
      # The output is left as-is if nvlink fails.
      expect "$(FAKE=write FAKE_CONTENTS=note.o FAKE_STATUS=1 status ./nvlink -o failed.o)" 1 "nvlink's exit status"
      cmp failed.o note.o

      # Anything else the wrapper doesn't expect fails the link, before nvlink runs where possible.
      printf 'INPUT(${builtins.storeDir}/%s-x)\n' "$hash" > text
      FAKE=write FAKE_CONTENTS=text expectFailure "the output isn't an ELF file, but refers to the Nix store" \
        ./nvlink -o result
      printf '\x7fELF' > truncated
      FAKE=write FAKE_CONTENTS=truncated expectFailure "the output is a malformed ELF file" ./nvlink -o result
      { printf '\x7fELF\x01\x01'; head -c 58 /dev/zero; } > elf32
      FAKE=write FAKE_CONTENTS=elf32 expectFailure "the output isn't a 64-bit little-endian ELF file" ./nvlink -o result
      FAKE=exit FAKE_STATUS=0 expectFailure "/dev/null is not a regular file" ./nvlink -o /dev/null
      echo kept > kept
      FAKE=exit FAKE_STATUS=0 expectFailure "nvlink didn't write kept" ./nvlink -o kept
      expect "$(cat kept)" kept "an output nvlink didn't write"
      rm log
      FAKE=exit FAKE_STATUS=0 expectFailure "-o is missing its value" ./nvlink -o
      printf '%s' '-o "unterminated' > unterminated.optf
      FAKE=exit FAKE_STATUS=0 expectFailure "an options file ends in a backslash or a quotation" \
        ./nvlink -optf unterminated.optf
      printf '%s' '-optf self.optf' > self.optf
      FAKE=exit FAKE_STATUS=0 expectFailure "options files are nested too deeply" ./nvlink -optf self.optf
      FAKE=exit FAKE_STATUS=0 expectFailure "options file /dev/fd/" ./nvlink -optf <(echo -o result)
      FAKE=exit FAKE_STATUS=0 expectFailure "options file missing.optf is missing or not a regular file" \
        ./nvlink -optf missing.optf
      if [[ -e log ]]; then
        nixErrorLog "expected nvlink not to run"
        exit 1
      fi
    '').overrideAttrs
      (prevAttrs: {
        nativeBuildInputs = prevAttrs.nativeBuildInputs ++ [ python3 ];
      });
}
// lib.optionalAttrs recordsCommandLine {
  # Link-time optimization also records -nvvmpath, which is in cuda_nvcc.
  # NOTE: With caller.cu and answer.cu, only ptxas records its command line.
  nvcc-lto = mkTest "nvcc-lto" ''
    nvcc -arch="$arch" -rdc=true -dlto gpu-check.cu -L${cudadevrtDir} -o result
    checkNotes result
    [[ $(nvlinkOptions result) == *-dlto* ]]
  '';
}
//
  lib.optionalAttrs (cudaAtLeast "12.8" && cudaOlder "13.0" && !backendStdenv.hostPlatform.isx86_64)
    {
      # Clang links relocatable device code by running nvlink from its CUDA path, through clang-nvlink-wrapper, which
      # also passes Clang's own library directory.
      # NOTE: Clang 21 fails to parse CUDA 13's headers. On x86_64, the Clang wrapper passes -mtls-dialect=gnu2, which
      # Clang rejects for the device code.
      clang-gpu-rdc =
        let
          clang = llvmPackages.clang;
        in
        (mkTest "clang-gpu-rdc" ''
          # A CUDA installation laid out as Clang expects, linking to the wrapper as cudatoolkit does.
          toolkit=$PWD/toolkit
          mkdir -p "$toolkit/bin" "$toolkit/include"
          ln -s ${cuda_nvcc}/bin/{*,.nvlink-wrapped} "$toolkit/bin/"
          ln -s ${cuda_nvcc}/nvvm "$toolkit/nvvm"
          ln -s ${lib.getLib cuda_cudart}/lib "$toolkit/lib64"
          for dir in ${
            lib.concatMapStringsSep " " (p: "${lib.getInclude p}/include") [
              cccl
              cuda_cudart
              cuda_nvcc
              libcurand
            ]
          }; do
            ln -sf "$dir"/* "$toolkit/include/"
          done
          ${lib.getExe' clang "clang++"} -x cuda --cuda-path="$toolkit" --offload-arch="$arch" --offload-new-driver \
            -fgpu-rdc -Wno-unknown-cuda-version caller.cu answer.cu \
            -L${cudadevrtDir} -lcudart_static -ldl -lrt -lpthread \
            -o result
          checkNotes result
        '').overrideAttrs
          (prevAttrs: {
            # Clang applies them to the device code too, for which some (e.g. zerocallusedregs) are unsupported.
            hardeningDisable = [ "all" ];
            disallowedRequisites = prevAttrs.disallowedRequisites ++ [ clang.cc ];
          });
    }
