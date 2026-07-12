let versions = [
      { nixpkgs = "nixos-26.05"; compiler = "ghc912"; }
    ];
    pkgs = import ./dep/ci/nixos-26.05 {};
    inherit (pkgs) lib;
    mkName = v: builtins.replaceStrings ["."] ["_"] "${v.compiler}-${v.nixpkgs}";
in
  builtins.listToAttrs (map (v: lib.nameValuePair (mkName v) (import ./. {
    ghc = v.compiler;
    pkgs = import (./dep/ci + "/${v.nixpkgs}") {};
  }).command) versions)
