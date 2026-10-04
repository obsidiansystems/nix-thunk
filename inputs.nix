let flakeInputs = (import
      (let lock = builtins.fromJSON (builtins.readFile ./flake.lock);
       in fetchTarball {
         url = "https://github.com/${lock.nodes.flake-compat.locked.owner}/${lock.nodes.flake-compat.locked.repo}/archive/${lock.nodes.flake-compat.locked.rev}.tar.gz";
         sha256 = lock.nodes.flake-compat.locked.narHash;
       }) { src = ./.; }
    ).outputs.inputs;

    flakeSrcs = builtins.mapAttrs (_: v: v.src or v) flakeInputs;

    thunkSrcs = import ./nix/libs/thunks.nix ./dep;

in flakeSrcs // thunkSrcs
