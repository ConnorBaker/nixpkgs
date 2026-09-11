# Paths stay structural until readDir needs a filesystem name. No CMake source is interpreted.
{ lib }:
{
  src,
  subtrees,
  excludeProjects ? { },
}:
let
  walk =
    path: exclusions:
    let
      entries = builtins.readDir (src + "/${lib.concatStringsSep "/" path}");
      project = entries."CMakeLists.txt" or null == "regular";
      aggregate = lib.isString exclusions;
      directories = lib.filterAttrs (_: type: type == "directory") entries;
      children = lib.filterAttrs (_: child: child != { }) (
        lib.mapAttrs (
          name: _: walk (path ++ [ name ]) (if aggregate then { } else exclusions.${name} or { })
        ) directories
      );
    in
    assert lib.assertMsg (
      if aggregate then
        project && exclusions != ""
      else
        lib.isAttrs exclusions && lib.all (name: directories ? ${name}) (lib.attrNames exclusions)
    ) "sample ${lib.showAttrPath path}: exclusions must name CMake aggregates with a reason";
    if project && !aggregate then
      assert lib.assertMsg (
        exclusions == { }
      ) "sample ${lib.showAttrPath path}: cannot exclude children of a project leaf";
      null
    else
      assert lib.assertMsg (
        !(directories ? recurseForDerivations)
      ) "sample ${lib.showAttrPath path}: directory name collides with the Nixpkgs traversal marker";
      assert lib.assertMsg (
        !aggregate || children != { }
      ) "sample ${lib.showAttrPath path}: an aggregate must have independent project descendants";
      children;
  tree = lib.genAttrs subtrees (name: walk [ name ] (excludeProjects.${name} or { }));
in
assert lib.assertMsg (
  subtrees != [ ]
  && lib.all (
    name:
    name != ""
    && name != "."
    && name != ".."
    && name != "recurseForDerivations"
    && !(lib.hasInfix "/" name)
  ) subtrees
) "sample subtrees must name top-level directories";
assert lib.assertMsg (lib.all (name: lib.elem name subtrees) (
  lib.attrNames excludeProjects
)) "sample exclusions name an unselected subtree";
assert lib.assertMsg (lib.all (node: node != { }) (
  lib.attrValues tree
)) "a selected sample subtree contains no CMake projects";
tree
