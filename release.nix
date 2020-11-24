let ghcs = [ "ghc865" "ghc884" ];
in map (ghc: import ./. { inherit ghc; }) ghcs
