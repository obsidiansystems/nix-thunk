# This file takes the same arguments as lib.nix. The defaults compute the system
# themselves, and a flake cannot do that. So flake.nix builds a package set for
# one system and passes that set here.
{
  system ? builtins.currentSystem,
  inputs ? import ./inputs.nix,
  haskell-nix ? import inputs.haskell-nix { inherit system; },
  pkgs ? import haskell-nix.sources.nixpkgs
    (haskell-nix.nixpkgsArgs // { localSystem = { inherit system; }; }),
}:

let
  nix-thunk = import ./lib.nix { inherit system inputs haskell-nix pkgs; };
  project = (nix-thunk.perGhc {}).project;
in
project.shellFor {
  packages = ps: [ ps.nix-thunk ];

  tools = {
    cabal = "latest";
    haskell-language-server = "latest";
    hlint = "latest";
  };
}
