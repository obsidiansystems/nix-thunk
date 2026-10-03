{
  inputs = {
    self.submodules = true;

    haskell-nix.url = ./dep/haskell.nix;
    gitignore.url = ./dep/gitignore.nix;

    nixpkgs.follows = "haskell-nix/nixpkgs";

    flake-compat.url = "github:NixOS/flake-compat";
  };

  outputs = inputs@{ self, ... }:
    let nixpkgs = if inputs ? "nixpkgs" then inputs.nixpkgs else builtins.getFlake "nixpkgs";
        eachSystem = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;

        # The entry points below take no `system`, because they must also work
        # outside a flake. So this flake builds a package set for one system and
        # passes that set to each entry point. Outside a flake they read
        # inputs.nix instead, and reach the same sources.
        pkgsFor = system: inputs.haskell-nix.legacyPackages.${system};
        nixThunkFor = system: import ./default.nix { inherit inputs; pkgs = pkgsFor system; };
    in {
      lib = eachSystem (system:
        let nix-thunk = nixThunkFor system;
        in {
          inherit (nix-thunk) thunkSource mapSubdirectories;
        }
      );

      packages = eachSystem (system:
        let nix-thunk = (nixThunkFor system).command;
        in {
          inherit nix-thunk;
          default = nix-thunk;
        }
      );

      legacyPackages = eachSystem (system: {
        release = import ./release.nix { inherit inputs; pkgs = pkgsFor system; };
      });

      devShells = eachSystem (system: {
        default = import ./shell.nix { inherit inputs; pkgs = pkgsFor system; };
      });
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nixcache.reflex-frp.org"
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI=" # reflex-frp
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = "true";
  };
}
