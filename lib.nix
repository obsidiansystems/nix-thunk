# This file is for building `nix-thunk` with arbitrary GHC, currently
# using `haskell.nix`. For *using* `nix-thunk`, you just need `default.nix`.
#
# This file is UNSTABLE, and should not be used in downstream projects
# accordingly.

let defaultInputs = import ./defaultInputs.nix; in
{
  haskell-nix ? defaultInputs.haskell-nix {},
  pkgs ? defaultInputs.pkgs { inherit haskell-nix; },
}:

rec {
  inherit haskell-nix pkgs;

  inherit (pkgs) lib;

  postInstallGenerateOptparseApplicativeCompletion = exeName: ''
      bashCompDir="''${!outputBin}/share/bash-completion/completions"
      zshCompDir="''${!outputBin}/share/zsh/vendor-completions"
      fishCompDir="''${!outputBin}/share/fish/vendor_completions.d"
      mkdir -p "$bashCompDir" "$zshCompDir" "$fishCompDir"
      "''${!outputBin}/bin/${exeName}" --bash-completion-script "''${!outputBin}/bin/${exeName}" >"$bashCompDir/${exeName}"
      "''${!outputBin}/bin/${exeName}" --zsh-completion-script "''${!outputBin}/bin/${exeName}" >"$zshCompDir/_${exeName}"
      "''${!outputBin}/bin/${exeName}" --fish-completion-script "''${!outputBin}/bin/${exeName}" >"$fishCompDir/${exeName}.fish"
      # Sanity check
      grep -F ${exeName} <$bashCompDir/${exeName} >/dev/null || {
        echo 'Could not find ${exeName} in completion script.'
        exit 1
      }
    '';

  haskellPackageSource = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "nix-thunk";
    src = ./.;
  };

  perGhc =
    { ghc ? (import ./versions.nix).ghc.preferred }:

    rec {
      # The Haskell.nix project that is used to build this by default
      project = pkgs.haskell-nix.project {
        src = haskellPackageSource;
        compiler-nix-name = ghc;
        modules = [
          ({...}: {
            packages.cli-git.components.library.build-tools = [
              pkgs.git
            ];
            packages.cli-nix.components.library.build-tools = [
              pkgs.nix-prefetch-git
              pkgs.nix # For nix-prefetch-url
            ];
            packages.nix-thunk.components.exes.nix-thunk = {
              enableStatic = true;
              postInstall = postInstallGenerateOptparseApplicativeCompletion "nix-thunk";
            };
          })
        ];
      };

      # The nix-thunk command itself; if you just want to use nix-thunk, this is the
      # thing to install
      command = project.nix-thunk.components.exes.nix-thunk;
    };

  inherit (import ./dep/gitignore.nix { inherit lib; }) gitignoreSource;

  inherit (import ./. { inherit pkgs gitignoreSource; })
    thunkSource
    mapSubdirectories
    ;

  # The version of nixpkgs that we use for fetching packing thunks (by
  # themselves). If you need to ensure that nix-thunk will work without a
  # network connection, make sure this is in your nix store. Not to be used for
  # building packages.
  packedThunkNixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
    sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
  };
}
