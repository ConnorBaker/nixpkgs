{ lib, stdenv }:
{
  name,
  source,
  description,
  flags ? [ ],
}:
stdenv.mkDerivation {
  __structuredAttrs = true;
  strictDeps = true;

  inherit name;

  src = source;
  dontUnpack = true;
  dontConfigure = true;

  # A caller may have a different libstdc++ on its LD_LIBRARY_PATH.
  buildPhase = ''
    runHook preBuild
    "$CXX" -std=c++23 -O2 -Wall -Wextra -static-libstdc++ -static-libgcc \
      -I "${./include}" ${lib.escapeShellArgs flags} "$src" \
      -o ${lib.escapeShellArg name}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D --mode=0755 ${lib.escapeShellArg name} "$out/bin"/${lib.escapeShellArg name}
    runHook postInstall
  '';

  meta = {
    inherit description;
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    teams = [ lib.teams.cuda ];
  };
}
