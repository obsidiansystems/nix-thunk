let versions = import ./versions.nix;
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
    ) versions.ghc.supported) // { recurseForDerivations = true; };
in byGhc
