(import ./default.nix {}).project.shellFor {
  tools = {
    cabal = "latest";
    haskell-language-server = "latest";
  };
}
