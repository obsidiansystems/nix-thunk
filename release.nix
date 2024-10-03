let versions = import ./versions.nix;
    nix-thunk = import ./lib.nix {};
    instances = builtins.listToAttrs (map (ghcVersion: {
      name = ghcVersion;
      value = nix-thunk.perGhc { ghc = ghcVersion; };
    }) versions.ghc.supported);
    preferredInstance = instances.${versions.ghc.preferred};
    pkgs = preferredInstance.project.pkgs;
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
    src = nix-thunk.src;
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
