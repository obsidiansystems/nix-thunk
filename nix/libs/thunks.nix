# Resolve every subdirectory of `dir` through ./thunk.nix. The result maps
# dependency name to source. Equivalent to nix-thunk's
# `mapSubdirectories thunkSource`.
#
# Example:
#
#   import ./thunks.nix ../pins
#   => { haskell-nix = <source>; nixpkgs = <source>; }
dir:

let entries = builtins.readDir dir;

    thunkSource = import ./thunk.nix;

    directories = builtins.filter
      (name: entries.${name} == "directory")
      (builtins.attrNames entries);

    entryFor = name: {
      inherit name;
      value = thunkSource (dir + "/${name}");
    };

in builtins.listToAttrs (map entryFor directories)
