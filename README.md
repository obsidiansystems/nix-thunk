nix-thunk
=========
[![Haskell](https://img.shields.io/badge/language-Haskell-orange.svg)](https://haskell.org) [![Hackage](https://img.shields.io/hackage/v/nix-thunk.svg)](https://hackage.haskell.org/package/nix-thunk) [![Github CI](https://github.com/obsidiansystems/nix-thunk/workflows/github-action/badge.svg)](https://github.com/obsidiansystems/nix-thunk/actions) [![BSD3 License](https://img.shields.io/badge/license-BSD3-blue.svg)](https://github.com/obsidiansystems/nix-thunk/blob/master/LICENSE)

nix-thunk is a lightweight Nix dependency manager, focused on making it easy to contribute improvements back to libraries you depend on.

nix-thunk does this by creating and managing "thunks" - directories that stand in for full git repositories.
Like git submodules, they pin a specific commit of the target repository, but unlike git submodules, you don't have to clone them to use them.
nix-thunk makes them "transparent" to Nix scripts, so any script that calls `import path/to/some/thunk` will work the same on the thunk as it does on the original repository.

* [Installation](#installation)
* [Command Usage](#command-usage)
  * [Create a dependency](#create-a-dependency)
  * [Work on a dependency](#work-on-a-dependency)
  * [Update a dependency](#update-a-dependency)
* [Nix Usage](#nix-usage)
* [Contributing](#contributing)
* [License](#license)

## Installation

```bash
nix-env -f https://github.com/obsidiansystems/nix-thunk/archive/master.tar.gz -iA command
```

**WARNING**: It is _not_ possible to compile `nix-thunk` without Nix.
To ensure that packed thunks are buildable even in environments where diamond paths are unavailable (specifically `<nixpkgs>`), `nix-thunk` _must_ be built with knowledge of a known-good nixpkgs, _and_ for `nix-thunk` to be able to manipulate these thunks, it must _always_ be the same version of nixpkgs.

## Command Usage

### Create a dependency

```bash
nix-thunk create https://example.com/some-dep
```

If you have already cloned the dependency as a git repository, you can just `pack` it instead:

```bash
nix-thunk pack some-dep
```

### Work on a dependency

If you discover a bug fix or improvement that your dependency needs, you can use `nix-thunk unpack path/to/your/dependency` to turn the thunk back into a full checkout of the repository.
Your Nix scripts should continue working, and you can modify the dependency's source code, push it to a branch or a fork, send a pull request, and then use `nix-thunk pack path/to/your/dependency` to pack it back up into a thunk.
When the dependency accepts your pull request, you can easily update the thunk.

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

## Nix Usage

The [`default.nix`](default.nix) file in this repository also defines the nix function, `thunkSource`.
This can be used in your nix files to access the contents of thunks.
In the following example, a thunk is used in place of the source location argument to `callCabal2nix`.
`thunkSource` works whether the thunk is packed or unpacked, making it convenient to run nix commands with modified thunks.

```nix
  haskellPackages = pkgs.haskell.packages.ghc865.override {
    overrides = self: super: {
      which = self.callCabal2nix "which" (thunkSource ./dep/which) {};
    };
  };
```

You can also represent in nix all the thunks of a given directory
```nix
let sources = nix-thunk.mapSubdirectories nix-thunk.thunkSource ./dep;
```
```nix
{ which = self.callCabal2nix "which" sources.which {}; }
```

You can also access subfolders of a thunk.
For example:

```nix
{
  imports = [ "${builtins.fetchTarball <some-tar-url>}/path/to/subfolder" ];
}
```
becomes
```
{
  imports = [ "${nix-thunk.thunkSource <thunk-location>}/path/to/subfolder>" ];
}
```

## Contributing

Pull requests are welcome.
For major changes, please open an issue first to discuss what you would like to change.
See the [contribution guide](CONTRIBUTING.md) for more details.

## License
[BSD3](./LICENSE)

***

![Obsidian Systems](https://obsidian.systems/static/images/ObsidianSystemsLogo.svg)
