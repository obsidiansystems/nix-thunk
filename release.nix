let versions = import ./versions.nix;
    instances = builtins.listToAttrs (map (ghcVersion: {
      name = ghcVersion;
      value = import ./lib.nix { ghc = ghcVersion; };
    }) versions.ghc.supported);
    preferredInstance = instances.${versions.ghc.preferred};
    pkgs = preferredInstance.project.pkgs;
    testsForInstance = name: this: {
      inherit (this) command;
      tests = import ./tests.nix {
        inherit (this) command packedThunkNixpkgs;
      };
      recurseForDerivations = true;
    };
in {
  # Instances of nix-thunk tested against different versions of its dependencies
  byGhc =
    builtins.mapAttrs testsForInstance instances //
    { recurseForDerivations = true; };
  check-hlint = pkgs.runCommand "check-hlint" {
    src = ./.;
    buildInputs = [
      (preferredInstance.project.tool "hlint" "latest")
    ];
  } ''
    set -euo pipefail

    cd "$src"
    hlint .

    touch "$out" # Make the derivation succeed if we get this far
  '';
}
