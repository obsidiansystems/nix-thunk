{ pkgs ? import ./dep/ci/nixos-21.05 {}
, ghc ? "ghc884"
}:

with pkgs.haskell.lib;

let
  inherit (pkgs) lib;
  pinnedNixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
    sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
  };
in rec {
  # Override a nix-thunk Cabal package so it knows where nixpkgs is.
  # This function is exported so that it can be used by downstream
  # consumers of nix-thunk as a library (e.g. Obelisk).
  makeRunnableNixThunk = pkg: pkgs.haskell.lib.overrideCabal pkg {
    librarySystemDepends = with pkgs; [
      # The correct reaction to this code is "what", followed by
      # some rather choice words about its author. The answer to
      # "what":
      # We need a known-good nixpkgs to be included in nix-thunk's
      # closure *and* we need to know its path at compile time. The
      # solution is to generate a tiny, tiny shell script that just
      # prints the path to that nixpkgs; Nix takes care of making
      # sure it's a dependency.
      (writeTextFile {
        name = "print-nixpkgs-path";
        text = ''
          #!/bin/sh
          echo "${pinnedNixpkgs}"
        '';
        executable = true;
        destination = "/bin/print-nixpkgs-path";
      })
      # You can verify that the nixpkgs was included by doing
      #
      #  $ nix-build default.nix -A command
      #  $ nix path-info -rsSh ./result | grep -source
      #
      # and seeing that the closure includes a ~100MiB nixpkgs path.
    ];
  };

  haskellPackages = pkgs.haskell.packages."${ghc}".override {
    overrides = self: super: {
      which = self.callCabal2nix "which" (thunkSource ./dep/which) {};
      cli-extras = self.callCabal2nix "cli-extras" (thunkSource ./dep/cli-extras) {};
      cli-nix = (import (thunkSource ./dep/cli-nix + "/overlays.nix")).cli-nix pkgs self;
      cli-git = pkgs.haskell.lib.overrideCabal (self.callCabal2nix "cli-git" (thunkSource ./dep/cli-git) {}) {
        librarySystemDepends = with pkgs; [
          git
        ];
      };
      github = self.callCabal2nix "github" (thunkSource ./dep/github) {};
      logging-effect = self.callHackageDirect {
        pkg = "logging-effect";
        ver = "1.3.11";
        sha256 = "0g4590zlnj6ycmaczkik011im4nlffplpd337g7nnasjw3wqxvdv";
      } {};
      unliftio-core = self.callHackageDirect {
        pkg = "unliftio-core";
        ver = "0.2.0.1";
        sha256 = "06cbv2yx5a6qj4p1w91q299r0yxv96ms72xmjvkpm9ic06ikvzzq";
      } {};
      prettyprinter = self.callHackageDirect {
        pkg = "prettyprinter";
        ver = "1.6.2";
        sha256 = "0ppmw0x2b2r71p0g43b3f85sy5cjb1gax8ik2zryfmii3b1hzz7c";
      } {};
      resourcet = self.callHackageDirect {
        pkg = "resourcet";
        ver = "1.2.4.2";
        sha256 = "1kwb0h7z1l5vvzrl2b4bpz15qzbgwn7a6i00fn2b7zkj1n25vmg8";
      } {};
      monad-logger = self.callHackageDirect {
        pkg = "monad-logger";
        ver = "0.3.36";
        sha256 = "0ba1liqvmwjcyz3smp9fh2px1kvz8zzbwcafm0armhwazlys1qh1";
      } {};
      base-compat = self.callHackageDirect {
        pkg = "base-compat";
        ver = "0.11.1";
        sha256 = "06030s3wzwkrm0a1hw4w7cd0nlrmxadryic4dr43kh380lzgdz58";
      } {};
      base-compat-batteries = self.callHackageDirect {
        pkg = "base-compat-batteries";
        ver = "0.11.1";
        sha256 = "1xsh4mcrmgiavgnkb5bg5lzxj1546525ffxjms3rlagf4jh9sn1i";
      } {};
      time-compat = self.callHackageDirect {
        pkg = "time-compat";
        ver = "1.9.5";
        sha256 = "0xy044x713bbvl8i1180bnccn60ji1n7mw1scs9ydy615bgwr82c";
      } {};
      ansi-terminal = self.callHackageDirect {
        pkg = "ansi-terminal";
        ver = "0.9.1";
        sha256 = "152lnv339fg8nacvyhxjfy2ylppc33ckb6qrgy0vzanisi8pgcvd";
      } {};
      nix-thunk = makeRunnableNixThunk (self.callCabal2nix "nix-thunk" (gitignoreSource ./.) {});
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
      if isObeliskThunkWithThunkNix then import (p + "/thunk.nix")
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
