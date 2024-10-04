# Private library functions.
#
# UNSTABLE, do not rely on this in external repos.
rec {
  contentsMatch = contents: { required, optional }:
       (let all = required // optional; in all // contents == all)
    && builtins.intersectAttrs required contents == required;

  # Newer obelisk thunks include the feature of hackGet with a thunk.nix file in the thunk.
  isThunkWithThunkNix = contents:
    let
      packed = jsonFileName: {
        required = { ${jsonFileName} = "regular"; "default.nix" = "regular"; "thunk.nix" = "regular"; };
        optional = { ".attr-cache" = "directory"; };
      };
    in builtins.any (n: contentsMatch contents (packed n)) [ "git.json" "github.json" ];
}
