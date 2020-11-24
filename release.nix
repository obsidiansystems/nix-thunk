let ghcPkgs = {
      ghc865 = (import ./dep/ci).nixos2003;
      ghc884 = (import ./dep/ci).nixos2003;
    };
in builtins.mapAttrs (ghc: pkgs: (import ./. { inherit ghc pkgs; }).command) ghcPkgs
