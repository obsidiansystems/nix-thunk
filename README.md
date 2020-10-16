# nix-thunk

nix-thunk is a lightweight Nix dependency manager, focused on making it easy to contribute improvements back to libraries you depend on.

## Installation

```bash
nix-env -f https://github.com/obsidiansystems/nix-thunk/archive/master.tar.gz -iA command
```

## Usage

### Create a dependency

In order to create a dependency, simply `git clone` it somewhere in your project; do **not** create a `git submodule` or `git subtree`.  Then, run `nix-thunk pack path/to/your/dependency`.  This will convert the git repository into a small directory of nix files that you can commit to your project's source control.  These files do two things: 1) precisely specify the repository and commit hash you are depending on, and 2) pretend that they *are* that repository.  If you use `import path/to/your/dependency` in your Nix scripts, the thunk will behave just like the git repository that it represents.

```bash
git clone https://example.com/some-dep
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
