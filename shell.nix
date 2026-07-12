let
  nix-thunk = import ./lib.nix {};
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
