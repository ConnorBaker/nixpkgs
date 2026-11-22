{ lib }:
{
  wrappers,
  directory ? "bin",
}:
lib.concatMapAttrsStringSep "\n" (
  name: wrapper:
  let
    installed = lib.escapeShellArg "${directory}/${name}";
    vendor = lib.escapeShellArg "${directory}/.${name}-wrapped";
  in
  ''
    nixLog ${lib.escapeShellArg "wrapping ${name}"}
    mv --verbose "''${!outputBin:?}"/${installed} "''${!outputBin:?}"/${vendor}
    install --mode=0755 ${lib.escapeShellArg (lib.getExe wrapper)} "''${!outputBin:?}"/${installed}
  ''
) wrappers
