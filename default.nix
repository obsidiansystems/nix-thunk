# This file is intended to be used in the Nix code of projects using
# `nix-thunk`. As such, it is supposed to be very stable.
#
# Packed thunks are self-contained, but the intended use-case of
# `nix-thunk` is that the ambient project should be able to use the
# thunk whether it is unpacked or not. That is a bit more tricky, and so
# that is what these functions help with.

{
  inputs ? import ./inputs.nix,
  haskell-nix ? import inputs.haskell-nix {},
  pkgs ? import haskell-nix.sources.nixpkgs haskell-nix.nixpkgsArgs,
  lib ? pkgs.lib,
  gitignoreSource ?
    (import inputs.gitignore { inherit lib; }).gitignoreSource,
}:

let myLib = import ./lib.nix { inherit inputs haskell-nix pkgs; }; in

rec {
  command = (myLib.perGhc {}).command;

  # Retrieve source that is controlled by the hack-* scripts; it may be either a
  # stub or a checked-out git repo
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
            # A newer version of nix-thunk writes flake.nix and flake.lock into
            # a thunk, and a consumer can then use that thunk as a flake input.
            # These files stay optional, so an older thunk still matches.
            optional = {
              ".attr-cache" = "directory";
              "flake.nix" = "regular";
              "flake.lock" = "regular";
            };
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

      # `nix-thunk unpack` writes these files into a checkout of a repository
      # that has no flake of its own. A consumer then keeps working while the
      # thunk stays unpacked. `nix-thunk` hides them from git through
      # .git/info/exclude, and `gitignoreSource` does not read that file, so
      # this filter drops them instead. An unpacked dependency must present the
      # same source as a packed thunk.
      #
      # These strings match what nix-thunk writes, byte for byte. See
      # `Nix.Thunk.Flake`. This filter compares content, and not names, so it
      # leaves a flake that the repository really owns in place.
      generatedFlakeFiles = {
        "flake.nix" = ''
          # DO NOT HAND-EDIT THIS FILE
          {
            description = "nix-thunk unpacked thunk";
            outputs = { self }: { src = self.sourceInfo; };
          }
        '';
        "flake.lock" = ''
          {
            "nodes": {
              "root": {}
            },
            "root": "root",
            "version": 7
          }
        '';
      };

      # This comparison ignores a final newline. nix-thunk writes these files
      # without a final newline, and Nix would add one if it rewrote the lock.
      sameFile = a: b: lib.removeSuffix "\n" a == lib.removeSuffix "\n" b;

      # This code wraps the caller's source, because `gitignoreSource` can
      # return a bare path or a filtered source. Either way `origSrc` names the
      # directory that the filter reads paths from.
      unfilteredSource = lib.cleanSourceWith { src = gitignoreSource p; };
      generatedFlakeFilePaths = builtins.filter
        (path:
             builtins.pathExists path
          && sameFile (builtins.readFile path) generatedFlakeFiles.${baseNameOf path})
        (map (name: toString unfilteredSource.origSrc + "/" + name)
             (builtins.attrNames generatedFlakeFiles));
      unpackedSource =
        if generatedFlakeFilePaths == []
        then gitignoreSource p
        else (lib.cleanSourceWith {
          inherit (unfilteredSource) name;
          src = unfilteredSource;
          filter = path: _: !(builtins.elem (toString path) generatedFlakeFilePaths);
        }).outPath;
    in
      if isObeliskThunkWithThunkNix then import (p + "/thunk.nix")
      else if hasValidThunk "git.json" then (
        let gitJson = builtins.fromJSON (builtins.readFile (p + "/git.json"));
            branch = gitJson.branch or null;
            isPrivate = gitJson.private or (lib.hasInfix "@" gitJson.url);
            fetchSubmodules = gitJson.fetchSubmodules or false;
            # builtins.fetchGit runs in the evaluator, so it has the caller's ssh
            # credentials.
            useFetchGit = isPrivate && !fetchSubmodules;
            refArgs = lib.optionalAttrs (branch != null) { ref = branch; };
            fetchGitArgs = {
              inherit (gitJson) url rev;
              allRefs = branch == null;
            } // refArgs;
            # pkgs.fetchgit supports neither `branch` nor `private`.
            fetchgitArgs = removeAttrs gitJson [ "branch" "private" ];
        in if useFetchGit
          then builtins.fetchGit fetchGitArgs
          else pkgs.fetchgit fetchgitArgs
        )
      else if hasValidThunk "github.json" then
        pkgs.fetchFromGitHub (filterArgs (builtins.fromJSON (builtins.readFile (p + "/github.json"))))
      else {
        name = baseNameOf p;
        outPath = unpackedSource;
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
