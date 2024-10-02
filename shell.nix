(import ./default.nix {}).project.shellFor {
  tools = {
    cabal = "latest";
  };
}
