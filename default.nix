{ pkgs ? (import ./dep/ci).nixos2003
, ghc ? "ghc884"
}:

with pkgs.haskell.lib;

let
  inherit (pkgs) lib;

in rec {
  haskellPackages = pkgs.haskell.packages."${ghc}".override {
    overrides = self: super: {
      which = self.callCabal2nix "which" (thunkSource ./dep/which) {};
      cli-extras = self.callCabal2nix "cli-extras" (thunkSource ./dep/cli-extras) {};
      cli-nix = self.callCabal2nix "cli-nix" (thunkSource ./dep/cli-nix) {};
      cli-git = self.callCabal2nix "cli-git" (thunkSource ./dep/cli-git) {};
      github = self.callCabal2nix "github" (thunkSource ./dep/github) {};
      nix-thunk = self.callCabal2nix "nix-thunk" (gitignoreSource ./.) {};
    };
  };

  command = generateOptparseApplicativeCompletion "nix-thunk" (justStaticExecutables haskellPackages.nix-thunk);

  inherit (import ./dep/gitignore.nix { inherit lib; }) gitignoreSource;

  # Retrieve source that is controlled by the hack-* scripts; it may be either a stub or a checked-out git repo
  thunkSource = p:
    let
      contents = builtins.readDir p;

      contentsMatch = { required, optional }:
           (let all = required // optional; in all // contents == all)
        && builtins.intersectAttrs required contents == required;

      # Newer obelisk thunks include the feature of hackGet with a thunk.nix file in the thunk.
      isObeliskThunkWithThunkNix =
        let
          packed = jsonFileName: {
            required = { ${jsonFileName} = "regular"; "default.nix" = "regular"; "thunk.nix" = "regular"; };
            optional = { ".attr-cache" = "directory"; };
          };
        in builtins.any (n: contentsMatch (packed n)) [ "git.json" "github.json" ];

      filterArgs = x: removeAttrs x [ "branch" ];
      hasValidThunk = name: if builtins.pathExists (p + ("/" + name))
        then
          contentsMatch {
            required = { ${name} = "regular"; };
            optional = { "default.nix" = "regular"; ".attr-cache" = "directory"; };
          }
          || throw "Thunk at ${toString p} has files in addition to ${name} and optionally default.nix and .attr-cache. Remove either ${name} or those other files to continue (check for leftover .git too)."
        else false;
    in
      if isObeliskThunkWithThunkNix then import (p + /thunk.nix)
      else if hasValidThunk "git.json" then (
        let gitArgs = filterArgs (builtins.fromJSON (builtins.readFile (p + "/git.json")));
        in if builtins.elem "@" (lib.stringToCharacters gitArgs.url)
          then pkgs.fetchgitPrivate gitArgs
          else pkgs.fetchgit gitArgs
        )
      else if hasValidThunk "github.json" then
        pkgs.fetchFromGitHub (filterArgs (builtins.fromJSON (builtins.readFile (p + "/github.json"))))
      else {
        name = baseNameOf p;
        outPath = gitignoreSource p;
      };

  #TODO: This really shouldn't include *all* symlinks, just ones that point at directories
  mapSubdirectories = f: dir: lib.mapAttrs (name: _: f (dir + "/${name}")) (lib.filterAttrs (_: type: type == "directory" || type == "symlink") (builtins.readDir dir));

  ##############################################################################
  # Deprecated functions
  ##############################################################################

  thunkSet = builtins.trace "Warning: `thunkSet` is deprecated; use `mapSubdirectories thunkSource` instead" (mapSubdirectories thunkSource);

  filterGit = builtins.trace "Warning: `filterGit` is deprecated; switch to using `gitignoreSource`, which provides better filtering" (builtins.filterSource (path: type: !(builtins.any (x: x == baseNameOf path) [".git" "tags" "TAGS" "dist"])));

  hackGet = builtins.trace "Warning: hackGet is deprecated; it has been renamed to thunkSource" thunkSource;
}
