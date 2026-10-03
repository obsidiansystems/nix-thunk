# Revision history for nix-thunk

# Unreleased

* Packed thunks are now flakes. Alongside `default.nix` and `thunk.nix`, a
  packed thunk carries a generated `flake.nix` and `flake.lock`, so you can use
  a thunk as a flake input:

  ```nix
  inputs.mythunk.url = "path:./dep/mythunk";
  ```

  The thunk's flake forwards the outputs of the repository that it points at. It
  also exposes that repository's own inputs under their own names, and it pins
  each input to the revision that upstream locked. So `follows` works in both
  directions:

  ```nix
  inputs.someinput.follows = "mythunk/nixpkgs";        # read
  inputs.mythunk.inputs.nixpkgs.follows = "nixpkgs";   # override
  ```

  Every packed thunk exposes the fetched source as `src`, whether or not the
  repository has a flake of its own. A consumer needs it to read a path inside
  the repository, because the input's own `outPath` is the thunk directory:

  ```nix
  srcs = builtins.mapAttrs (_: v: v.src or v) inputs;
  obelisk-route = srcs.obelisk + "/lib/route";
  ```

  When the repository has a flake, `src` sits alongside that flake's outputs,
  and shadows an output of the same name.

  The flake interface survives `unpack` and `worktree`, so a project keeps
  building while you develop a dependency. For a repository that is not a flake,
  `nix-thunk` writes the same files into the checkout and hides them through
  git's `info/exclude`. `pack` removes them again. `nix-thunk` writes nothing
  when the repository already has a `flake.nix` or a `flake.lock`. It also
  leaves a `flake.nix` that you wrote yourself in place.

  This release introduces the `github-v9` and `git-v10` thunk specs. They fetch
  exactly as `github-v8` and `git-v9` do, and they add the flake files. Please
  update all your thunks:
  `nix-thunk unpack $path; nix-thunk pack $path`.

  **Breaking:** the two extra files mean that a packed thunk no longer matches
  the `thunkSource` in an older vendored copy of this repository's
  `default.nix`. Such a copy rejects any file that it does not recognise. A
  project that pins an older nix-thunk for its Nix code must update that pin
  before it updates its thunks.

* A packed thunk now resolves under a pure evaluation, so `import ./dep/mythunk`
  works inside a flake:

  ```nix
  mypkg = import inputs.mythunk { inherit system; };
  ```

  `github-v9` imports a pinned nixpkgs for a private or submodule thunk.
  `git-v10` imports one for every thunk but a private one with no submodules.
  That import reads `builtins.currentSystem`, which a pure evaluation does not
  have, so it fails with `error: attribute 'currentSystem' missing`.

  This release introduces the `github-v10` and `git-v11` thunk specs. Each adds
  a branch for an evaluation without `builtins.currentSystem`. That branch
  fetches with `builtins.fetchTree`, which needs no package set. Please update
  all your thunks: `nix-thunk unpack $path; nix-thunk pack $path`.

  `github-v10` fetches every other case as `github-v8` does.

  `git-v11` also checks `sha256` for a private thunk with no submodules, which
  `git-v10` did not. That fetch keeps `builtins.fetchGit` and the caller's own
  credentials.

  Both specs check `sha256` only on Nix 2.19 and newer, which has
  `builtins.convertHash`. An older Nix pins by revision alone, as before.

* `create`, `pack` and `update` accept `--no-flake`, which writes a thunk in the
  newest format that carries no flake files. You cannot use such a thunk as a
  flake input, so the flag serves a project that does not want the interface.
  The format belongs to the thunk, and not to the tool. `unpack` keeps the
  format that the thunk already had, and a pack without the flag moves a thunk
  to the newest format.

* A pack no longer fetches the repositories that a flake dependency points at.
  `nix-thunk` writes the generated `flake.lock` from upstream's own lock, which
  already records every reference and hash that the lock needs. `nix-thunk` does
  not run `nix flake lock` over inputs that Nix would resolve one at a time. So
  a pack of a thunk of a repository with a large dependency graph no longer
  downloads that graph. It also no longer fails when one of its pins is
  unreachable.

  `nix-thunk` still asks Nix when it cannot restate an input, and the pack then
  takes as long as it did before. That happens in two cases:

  * Upstream declares an input as a path outside its own repository.
  * Upstream gives an input a name that Nix does not accept in a `follows`.

  haskell.nix, for example, has inputs with names like `hls-1.10`. A flake can
  declare such a name, and nothing can refer to it.

* The attribute cache moved out of the thunk directory, into
  `$XDG_CACHE_HOME/nix-thunk`. A consumer now also reads a packed thunk as a
  flake input, so Nix hashes everything inside the thunk into that consumer's
  `flake.lock`. A cache inside the thunk would therefore change the thunk when
  somebody built one of its attributes. `nix-thunk` still accepts a leftover
  `.attr-cache` directory, so an existing thunk still reads as a thunk. No code
  writes to that directory now, and you can delete it.

* Drop support for GHC older than 9.12. `Nix.Thunk.Flake` uses
  `MultilineStrings`, and that extension requires 9.12. This release also bumps
  the `haskell.nix` pin.

* Add a `--version` option to the `nix-thunk` executable.

## 0.7.3.0

* Add `runMonadNixThunk` to make it easier to run the actions defined in the library.

## 0.7.2.2

* Support GHC 9.12

## 0.7.2.1
* Loosen version bounds
* Fix issue where thunk branches aren't updated when the user specifies --branch on nix-thunk update
* Swap default.nix and lib.nix

## 0.7.2.0
* Support retrieving revs that aren't on the default branch when a branch isn't specified.  To use this functionality, update your thunks.

## 0.7.1.0
* Allow specifying `--rev` when doing `update` to update to a specific revision.

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
