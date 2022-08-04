# Revision history for nix-thunk

## 0.5.0.0

* Fix a critical bug where v6 thunks can not be used to fetch non-GitHub repositories. Please update all your thunks to use the new v7 thunk spec.
  Updating your thunk can be done by running `nix-thunk unpack $path; nix-thunk pack $path`.
* Building a functional `nix-thunk` _must_ be done using the included Nix derivation.

## 0.4.0.0

* The default thunk specification ("v6") now uses a pinned version of nixpkgs, rather than the magic `<nixpkgs>`, for fetching thunks. This ensures that thunks can be fetched even in an environment where `NIX_PATH` is unset.

## 0.3.0.0

* Fix readThunk when thunk is checked out [#4](https://github.com/obsidiansystems/nix-thunk/pull/4)
* Fix removal of .git from default destination [#10](https://github.com/obsidiansystems/nix-thunk/pull/10)

## 0.2.0.3

* Default to GHC 8.8.4 and update dependency bounds

## 0.2.0.2
* Add support for GHC 8.8.4.

## 0.2.0.1
* Fix parsing of --rev arguments

## 0.2.0.0
* Add nix-thunk create.  This caused some minor breakage to the Haskell library API, but not the Nix or command line interfaces.

## 0.1.0.0
* Initial release.  Extracted the Nix part of this code from https://github.com/obsidiansystems/reflex-platform and the Haskell part from https://github.com/obsidiansystems/obelisk
