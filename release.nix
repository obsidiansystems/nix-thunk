let supportedGhcVersions = [
      "ghc8107"
      "ghc928"
      "ghc948"
      "ghc965"

      # 9.8.2 is not yet supported because some deps have base constraints that
      # prevent it.  There are not any known fundamental issues.
    ];
    byGhc = builtins.listToAttrs (map (ghcVersion:
      let this = import ./default.nix { ghc = ghcVersion; };
      in {
        name = ghcVersion;
        value = {
          inherit (this) command;
          tests = import ./tests.nix {
            inherit (this) command packedThunkNixpkgs;
          };
          recurseForDerivations = true;
        };
      }
    ) supportedGhcVersions) // { recurseForDerivations = true; };
in byGhc
