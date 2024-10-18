{
  haskell-nix = {}: import ./dep/haskell.nix {};
  pkgs = { haskell-nix }: import haskell-nix.sources.nixpkgs haskell-nix.nixpkgsArgs;
}
