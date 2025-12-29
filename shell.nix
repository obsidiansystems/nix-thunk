((import ./lib.nix {}).perGhc {}).project.shellFor {
  tools = {
    cabal = "latest";
    haskell-language-server = "latest";
    hlint = "latest";
  };
}
