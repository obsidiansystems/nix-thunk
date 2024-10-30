{ pkgs ? import <nixpkgs> {}
}:
rec {
  this = import ./lib.nix {};
  inherit ((this.perGhc {}).project.nix-thunk.components.library) env;
  builder = pkgs.writeShellScript "build-ghc" ''
    ${env}/bin/ghc -fbuilding-cabal-package -O -static -dynamic-too -dynosuf dyn_o -dynhisuf dyn_hi -outputdir dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -odir dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -hidir dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -hiedir dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/extra-compilation-artifacts/hie -stubdir dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -i -isrc -idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/autogen -idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/global-autogen -Idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/autogen -Idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/global-autogen -Idist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build -optP-include -optPdist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/autogen/cabal_macros.h -this-unit-id nix-thunk-0.7.2.0-inplace -hide-all-packages -Wmissing-home-modules -no-user-package-db -package-db ${env}/configFiles/lib/ghc-9.8.2/lib/package.conf.d -package-id aeson-2.2.3.0-LKc7Q8KzkN64PwxkwZL6Vu -package-id aeson-pretty-0.8.10-8Grz6bj8QQJ5cfSRIPhj5P -package-id base-4.19.1.0-inplace -package-id bytestring-0.11.5.3-BPcJcNp6CaGFOh4pLr9OGC -package-id cli-extras-0.2.1.0-IvPxMPhMi9fLZAFnmYv2Wn -package-id cli-git-0.2.0.1-2lyxFAviNkJDnGo9iXT9QA -package-id cli-nix-0.2.0.0-LskLpdUGrExlQZoePfmAW -package-id containers-0.6.8-inplace -package-id cryptonite-0.30-6WX8eixAhSB2aHtKghX3JY -package-id data-default-0.7.1.1-KPNBwVzvetOBTvqsuLYoYI -package-id directory-1.3.7.1-2CEvHxuB8Ly4S7qRYQ7sO1 -package-id either-5.0.2-uRWOuqt00EIkKnhprVa1I -package-id exceptions-0.10.7-inplace -package-id extra-1.7.16-AgBkU5EW7XSISThRT3WaGn -package-id filepath-1.4.300.2-IncSCrtbudn906gU2lA2Ej -package-id github-0.29-BdbOtyrFJoQIOwjg8NFeMW -package-id here-1.2.14-DpBMTmQlLnVKUCFpH74laS -package-id lens-5.3.2-4yCaWwpl7NTD5vsmaR1z8B -package-id logging-effect-1.4.0-FK1SdcMcm0MBu9vDa293pM -package-id megaparsec-9.6.1-H8fp1L70nOG4zfvCdgKv9m -package-id memory-0.18.0-C8QqX8LBf8LECON9BYf7za -package-id modern-uri-0.3.6.1-EPUdrQ6vrESAfFdyj8iyER -package-id monad-logger-0.3.40-6xmyGwyNnsd85bIelyGmMh -package-id mtl-2.3.1-inplace -package-id optparse-applicative-0.16.1.0-LY15Wk998KhJBP9F3HQ6Bi -package-id temporary-1.3-ALKh5BUsGExIoa5alKGtYb -package-id text-2.1.1-CGzymvGK5WhB3o14fYVccR -package-id time-1.11.1.2-70B2VY7qZIeCZBF7oJlbjQ -package-id unix-2.7.3-LF8b90rNb1i16Hue9HWCgD -package-id which-0.2.0.2-9X61ZMOzBer2It44yEUWm -package-id yaml-0.11.11.2-Ag0EvH4U4bI1wL79k8X5j0 -XHaskell2010 -Wall -hide-all-packages -c "$src"
    ${pkgs.coreutils}/bin/cp dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/Nix/Thunk/Internal.o "$out"
    ${pkgs.coreutils}/bin/cp dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/Nix/Thunk/Internal.hi "$hi"
    ${pkgs.coreutils}/bin/cp dist-newstyle/build/x86_64-linux/ghc-9.8.2/nix-thunk-0.7.2.0/build/Nix/Thunk/Internal.dyn_hi "$dyn_hi"
  '';
  splitPlaceholder = name:
    let p = builtins.placeholder name;
        l = builtins.stringLength p;
    in "\"" + builtins.substring 0 (l - 1) p + "\"\"" + builtins.substring (l - 1) 1 p + "\"";
  meta = pkgs.runCommand "meta-nix-thunk.drv" {
    src = ./.;
    requiredSystemFeatures = [ "recursive-nix" ];
    nativeBuildInputs = with pkgs; [
      nix
    ];
    __contentAddressed = true;
    outputHashMode = "text";
  } ''
    INTERNAL_HS="$(nix-store --add "$src/src/Nix/Thunk/Internal.hs")"
    O_OUT=${splitPlaceholder "out"}
    HI_OUT=${splitPlaceholder "hi"}
    DYN_HI_OUT=${splitPlaceholder "dyn_hi"}
    OUTPUT_DRV="$(nix --extra-experimental-features nix-command --extra-experimental-features ca-derivations --extra-experimental-features dynamic-derivations derivation add <<EOF
    {
      "args": [],
      "builder": "${builtins.unsafeDiscardStringContext builder}",
      "env": {
        "src": "$INTERNAL_HS",
        "out": "$O_OUT",
        "hi": "$HI_OUT",
        "dyn_hi": "$DYN_HI_OUT"
      },
      "inputDrvs": {
        "${builtins.unsafeDiscardStringContext builder.drvPath}": {
          "dynamicOutputs": {},
          "outputs": [
            "out"
          ]
        }
      },
      "inputSrcs": [
        "$INTERNAL_HS"
      ],
      "name": "meta-nix-thunk",
      "outputs": {
        "out": { "hashAlgo": "r:sha256" },
        "hi": { "hashAlgo": "r:sha256" },
        "dyn_hi": { "hashAlgo": "r:sha256" }
      },
      "system": "x86_64-linux"
    }
    EOF
    )"
    echo "$OUTPUT_DRV"
    cp "$OUTPUT_DRV" "$out"
  '';
}
