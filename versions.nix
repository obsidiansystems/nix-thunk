{
  ghc = rec {
    # FUTURE: It would be nice to have an automated check that this list is
    # up-to-date.  Generally we only want to support the newest minor release of
    # each GHC major release (i.e. maximum z in ghc-x.y.z) that is available in
    # our pin of haskell.nix.
    # NOTE: This should be in ascending order, with the newest GHC at the bottom
    supported = [
      "ghc8107"
      "ghc928"
      "ghc948"
      "ghc966"
      "ghc982"
      "ghc9101"
    ];
    # TODO change back to `- 1`, but hlint is having trouble with GHC 9.10
    preferred = builtins.elemAt supported (builtins.length supported - 2);
  };
}
