let versions = import ./versions.nix;
    nix-thunk = import ./packaging.nix {};
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
    src = nix-thunk.haskellPackageSource;
    buildInputs = [
      (preferredInstance.project.tool "hlint" "latest")
    ];
  } ''
    set -euo pipefail

    hlint --hint=${./.hlint.yaml} "$src"

    touch "$out" # Make the derivation succeed if we get this far
  '';

  # Test the interface of default.nix.  This should NOT be deduplicated, even if
  # it is building the same derivations as other parts of this file.
  command = (import ./default.nix {}).command;
}
