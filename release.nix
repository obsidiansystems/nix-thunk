{ inputs ? import ./inputs.nix
, haskell-nix ? import inputs.haskell-nix {}
, pkgs ? import haskell-nix.sources.nixpkgs haskell-nix.nixpkgsArgs
}:

let versions = import ./versions.nix;
    nix-thunk = import ./lib.nix { inherit inputs haskell-nix pkgs; };
    instances = builtins.listToAttrs (map (ghcVersion: {
      name = ghcVersion;
      value = nix-thunk.perGhc { ghc = ghcVersion; };
    }) versions.ghc.supported);
    testsForInstance = name: this: {
      inherit (this) command;
      tests = import ./tests.nix {
        inherit (this) command;
        inherit (nix-thunk) packedThunkNixpkgs;
      };
      recurseForDerivations = true;
    };
in {
  # Instances of nix-thunk tested against different versions of its dependencies
  byGhc =
    builtins.mapAttrs testsForInstance instances //
    { recurseForDerivations = true; };

  check-hlint = pkgs.runCommand "check-hlint" {
    src = nix-thunk.haskellPackageSource;
    buildInputs = [
      # The shared Obsidian hlint, from the style.hs submodule. The wrapper
      # supplies its own bundled config, so no --hint flag is needed here.
      #
      # Deliberately *not* given our own `pkgs`: style.hs pins the hlint it was
      # written against (3.10), while our nixpkgs has 3.8, and the two disagree
      # about which hints fire. Using its pin keeps CI in step with what
      # `nix run github:obsidiansystems/style.hs#hlint` reports locally.
      (import ./dep/style.hs/hlint.nix {})
    ];
  } ''
    set -euo pipefail

    hlint "$src"

    touch "$out" # Make the derivation succeed if we get this far
  '';

  check-fourmolu = pkgs.runCommand "check-fourmolu" {
    src = nix-thunk.haskellPackageSource;
    buildInputs = [
      # As with check-hlint, deliberately not given our own `pkgs`, so that CI
      # formats with the same fourmolu as `nix run github:obsidiansystems/style.hs`.
      (import ./dep/style.hs/fourmolu.nix {})
    ];
  } ''
    set -euo pipefail

    # --mode check exits non-zero rather than rewriting anything. The wrapper
    # supplies the bundled config, so no --config flag is needed.
    fourmolu --mode check "$src"

    touch "$out" # Make the derivation succeed if we get this far
  '';

  # Test the interface of default.nix.  This should NOT be deduplicated, even if
  # it is building the same derivations as other parts of this file.
  command = (import ./default.nix { inherit inputs haskell-nix pkgs; }).command;
}
