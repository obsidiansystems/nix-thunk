nix-thunk
=========
[![Haskell](https://img.shields.io/badge/language-Haskell-orange.svg)](https://haskell.org) [![Hackage](https://img.shields.io/hackage/v/nix-thunk.svg)](https://hackage.haskell.org/package/nix-thunk) [![Hackage CI](https://matrix.hackage.haskell.org/api/v2/packages/nix-thunk/badge)](https://matrix.hackage.haskell.org/#/package/nix-thunk) [![Github CI](https://github.com/obsidiansystems/nix-thunk/workflows/github-action/badge.svg)](https://github.com/obsidiansystems/nix-thunk/actions) [![BSD3 License](https://img.shields.io/badge/license-BSD3-blue.svg)](https://github.com/obsidiansystems/nix-thunk/blob/master/LICENSE)

nix-thunk is a lightweight Nix dependency manager, focused on making it easy to contribute improvements back to libraries you depend on.

nix-thunk does this by creating and managing "thunks" - directories that stand in for full git repositories.  Like git submodules, they pin a specific commit of the target repository, but unlike git submodules, you don't have to clone them to use them.  nix-thunk makes them "transparent" to Nix scripts, so any script that calls `import path/to/some/thunk` will work the same on the thunk as it does on the original repository.

## Installation

```bash
nix-env -f https://github.com/obsidiansystems/nix-thunk/archive/master.tar.gz -iA command
```

## Usage

### Create a dependency

```bash
nix-thunk create https://example.com/some-dep
```

If you have already cloned the dependency as a git repository, you can just `pack` it instead:

```bash
nix-thunk pack some-dep
```

### Work on a dependency

If you discover a bug fix or improvement that your dependency needs, you can use `nix-thunk unpack path/to/your/dependency` to turn the thunk back into a full checkout of the repository.  Your Nix scripts should continue working, and you can modify the dependency's source code, push it to a branch or a fork, send a pull request, and then use `nix-thunk pack path/to/your/dependency` to pack it back up into a thunk.  When the depenency accepts your pull request, you can easily update the thunk.

```bash
nix-thunk unpack some-dep
# Improve some-dep and push your work to a branch
nix-thunk pack some-dep
```

### Update a dependency

For routine updates, you can run `nix-thunk update path/to/your/dependency` to point the thunk at the latest version of the dependency without needing to do a `nix-thunk unpack` or a `git clone`.

```bash
nix-thunk update some-dep
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License
[BSD3](./LICENSE)
