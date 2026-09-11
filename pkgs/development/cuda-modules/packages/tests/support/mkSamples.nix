# The source and customization trees have the same branches; only project leaves are packages.
{
  mkSample,
  cuda-library-samples-src,
  discoverSampleProjects,
  lib,
}:
{
  component,
  subtrees,
  src ? cuda-library-samples-src,
  excludeProjects ? { },
  defaults ? { },
  fixups ? { },
}:
let
  shape = discoverSampleProjects { inherit src subtrees excludeProjects; };
  construct =
    path: node: changes:
    let
      args = {
        inherit component src;
        sampleRoot = lib.concatStringsSep "/" path;
      }
      // lib.toFunction defaults path;
    in
    if node == null then
      lib.makeOverridable mkSample (args // lib.toFunction changes args)
    else
      assert lib.assertMsg (
        lib.isAttrs changes && !lib.isFunction changes
      ) "sample ${lib.showAttrPath path}: a directory customization must be an attribute set";
      assert lib.assertMsg (lib.all (name: node ? ${name}) (
        lib.attrNames changes
      )) "sample ${lib.showAttrPath path}: customization names an undiscovered child";
      lib.recurseIntoAttrs (
        lib.mapAttrs (name: child: construct (path ++ [ name ]) child (changes.${name} or { })) node
      );
in
construct [ ] shape fixups
