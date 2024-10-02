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

      # 9.8.2 is not yet supported because some deps have base constraints that
      # prevent it.  There are not any known fundamental issues.
    ];
    preferred = builtins.elemAt supported (builtins.length supported - 1);
  };
}
