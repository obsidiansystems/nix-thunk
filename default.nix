# This file is intended to be used in the Nix code of projects using
# `nix-thunk`. As such, it is supposed to be very stable.
#
# Packed thunks are self-contained, but the intended use-case of
# `nix-thunk` is that the ambient project should be able to use the
# thunk whether it is unpacked or not. That is a bit more tricky, and so
# that is what these functions help with.

let defaultInputs = import ./defaultInputs.nix; in
{
  haskell-nix ? defaultInputs.haskell-nix {},
  pkgs ? defaultInputs.pkgs { inherit haskell-nix; },
  lib ? pkgs.lib,
  gitignoreSource ?
    (import ./dep/gitignore.nix { inherit lib; }).gitignoreSource,
}:

let

  myLib = import ./lib.nix { inherit haskell-nix pkgs; }; in

  inherit (import ./private.nix)
    contentsMatch
    isThunkWithThunkNix
    ;

in rec {

  command = (myLib.perGhc {}).command;

  # Retrieve source that is controlled by the hack-* scripts; it may be either a
  # stub or a checked-out git repo
  thunkSource = p:
    let
      contents = builtins.readDir p;
    in if isThunkWithThunkNix contents then import (p + "/thunk.nix")
    else let # legacy cases
      filterArgs = x: removeAttrs x [ "branch" ];
      hasValidThunk = name: if builtins.pathExists (p + ("/" + name))
        then
          contentsMatch contents {
            required = { ${name} = "regular"; };
            optional = { "default.nix" = "regular"; ".attr-cache" = "directory"; };
          }
          || throw "Thunk at ${toString p} has files in addition to ${name} and optionally default.nix and .attr-cache. Remove either ${name} or those other files to continue (check for leftover .git too)."
        else false;
    in
      if hasValidThunk "git.json" then (
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
