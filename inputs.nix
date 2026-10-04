let flakeInputs = (import
      (let lock = builtins.fromJSON (builtins.readFile ./flake.lock);
       in fetchTarball {
         url = "https://github.com/${lock.nodes.flake-compat.locked.owner}/${lock.nodes.flake-compat.locked.repo}/archive/${lock.nodes.flake-compat.locked.rev}.tar.gz";
         sha256 = lock.nodes.flake-compat.locked.narHash;
       }) { src = ./.; }
    ).outputs.inputs;

    flakeSrcs = builtins.mapAttrs (_: v: v.src or v) flakeInputs;

    thunkSource = path:
      if builtins.pathExists (path + "/thunk.nix")
      then import (path + "/thunk.nix")
      else path;
    thunkSources = dir:
      let entries = builtins.readDir dir;
          directories = builtins.filter
            (name: entries.${name} == "directory")
            (builtins.attrNames entries);
          entryFor = name: {
            inherit name;
            value = thunkSource (dir + "/${name}");
          };
      in builtins.listToAttrs (map entryFor directories);

    thunkSrcs = thunkSources ./dep;

in flakeSrcs // thunkSrcs
