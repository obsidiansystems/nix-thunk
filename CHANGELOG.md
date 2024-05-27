# Revision history for nix-thunk

## 0.7.0.1

* Support GHC 9.6

## 0.7.0.0

* Caching now works
* [#42](https://github.com/obsidiansystems/nix-thunk/pull/42) Thunk read errors are now presented in a more informative manner.
* [#43](https://github.com/obsidiansystems/nix-thunk/pull/43) `nix-thunk` will now ensure that any `git` processes invoked during its execution have a clean configuration. 
  This prevents `nix-thunk` crashing when e.g. the user's configuration `git` is valid only in a version newer than what `nix-thunk` links against, and works towards making thunks more reproducible by ensuring that thunk URIs are resolvable independently of the user's environment.

## 0.6.1.0

* [#36](https://github.com/obsidiansystems/nix-thunk/pull/36) Expose the internals of the `nix-thunk` library.

## 0.6.0.0

* [#34](https://github.com/obsidiansystems/nix-thunk/pull/34) Fix an
  issue where thunks could not be fetched without `nix-thunk` (or one of
  its dependents, e.g. `obelisk`) being installed. Please update all
  your thunks to use the new v8 thunk spec.

  Updating your thunk can be done by running `nix-thunk unpack $path; nix-thunk pack $path`.

* [#35](https://github.com/obsidiansystems/nix-thunk/pull/35) Determine remote using git-config when `branch.<name>.merge` option is set
  (Fixes [obelisk#792](https://github.com/obsidiansystems/obelisk/issues/792).)

## 0.5.1.0

* Bump to cli-nix 0.2.0.0; This ensures that `nix-prefetch-git` can always be found.

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
