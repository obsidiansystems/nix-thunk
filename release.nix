let versions = [
      { nixpkgs = "nixos-20.03"; compiler = "ghc865"; }
      { nixpkgs = "nixos-20.03"; compiler = "ghc884"; }
      { nixpkgs = "nixos-20.09"; compiler = "ghc865"; }
      { nixpkgs = "nixos-20.09"; compiler = "ghc884"; }
      { nixpkgs = "nixos-21.05"; compiler = "ghc884"; }
      { nixpkgs = "nixos-21.11"; compiler = "ghc8107"; }
      { nixpkgs = "nixos-22.05"; compiler = "ghc8107"; }
      { nixpkgs = "nixos-22.11"; compiler = "ghc8107"; }
      { nixpkgs = "nixos-23.05"; compiler = "ghc8107"; }
      { nixpkgs = "nixpkgs-unstable"; compiler = "ghc8107"; }
      { nixpkgs = "master"; compiler = "ghc8107"; }
    ];
    pkgs = import ./dep/ci/nixpkgs-unstable {};
    inherit (pkgs) lib;
    mkName = v: builtins.replaceStrings ["."] ["_"] "${v.compiler}-${v.nixpkgs}";
in
  builtins.listToAttrs (map (v: lib.nameValuePair (mkName v) (import ./. {
    ghc = v.compiler;
    pkgs = import (./dep/ci + "/${v.nixpkgs}") {};
  }).command) versions) // { tests = import ./tests.nix {}; }
