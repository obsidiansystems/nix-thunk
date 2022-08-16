{
  supportedSystems ? [ builtins.currentSystem ]
}:
let
  nix-thunk = import ./default.nix {};
  # Get a version of nixpkgs corresponding to release-22.05, which
  # contains the python based tests and recursive nix.
  pkgs = import (builtins.fetchTarball https://github.com/nixos/nixpkgs/archive/478f3cbc8448b5852539d785fbfe9a53304133be.tar.gz) {};
  sshKeys   = import (pkgs.path + /nixos/tests/ssh-keys.nix) pkgs;
  make-test = import (pkgs.path + /nixos/tests/make-test-python.nix);
  snakeOilPrivateKey = sshKeys.snakeOilPrivateKey.text;
  snakeOilPublicKey = sshKeys.snakeOilPublicKey;

  privateKeyFile = pkgs.writeText "id_rsa" ''${snakeOilPrivateKey}'';

  thunkableSample = pkgs.writeText "default.nix" ''
    let pkgs = import <nixpkgs> {}; in pkgs.git
  '';

  sshConfigFile = pkgs.writeText "ssh_config" ''
    Host *
      StrictHostKeyChecking no
      UserKnownHostsFile=/dev/null
      ConnectionAttempts=1
      ConnectTimeout=1
      IdentityFile=~/.ssh/id_rsa
      User=root
  '';

  # This is the version of nixpkgs that we use in thunks. It needs to be
  # included in the VM so that builtin.fetchgit succeeds without a
  # network connection.
  ourNixpkgs = nix-thunk.packedThunkNixpkgs;
in
  make-test ({...}: {
    name  = "nix-thunk";
    nodes = {
      githost = {
        networking.firewall.allowedTCPPorts = [ 22 80 443 ];
        services.openssh = {
          enable = true;
        };
        environment.systemPackages = [ pkgs.git ];
        users.users.root.openssh.authorizedKeys.keys = [
          snakeOilPublicKey
        ];
      };

      client = {
        imports = [ (pkgs.path + /nixos/modules/installer/cd-dvd/channel.nix) ];
        nix.useSandbox = false;
        nix.binaryCaches = [];
        environment.systemPackages = [
          pkgs.nix-prefetch-git nix-thunk.command pkgs.git pkgs.rsync ourNixpkgs
        ];
      };

      # This machine is used for testing that thunks can be built if
      # your nix-thunk is weird, wacky, dead, or not present at all. The
      # GCD of those failure modes is "not present at all", thus:
      noNixThunk = {
        imports = [ (pkgs.path + /nixos/modules/installer/cd-dvd/channel.nix) ];
        nix.useSandbox = false;
        nix.binaryCaches = [];
        environment.systemPackages = [ pkgs.git pkgs.rsync ourNixpkgs ];
      };
    };

    testScript =
      let
      in ''
      start_all()

      with subtest("nix-thunk is installed and git can be configured"):
        client.succeed("nix-thunk --help")
        client.succeed('git config --global user.email "you@example.com"')
        client.succeed('git config --global user.name "Your Name"')

      githost.wait_for_open_port("22")

      with subtest("the clients can access the server via ssh"):
        for machine in [client, noNixThunk]:
          machine.succeed("mkdir -p ~/.ssh/")
          machine.succeed("cp ${privateKeyFile} ~/.ssh/id_rsa")
          machine.succeed("chmod 600 ~/.ssh/id_rsa")
          machine.wait_until_succeeds(
            "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa githost true"
          )
          machine.succeed("cp ${sshConfigFile} ~/.ssh/config")
          machine.wait_until_succeeds("ssh githost true")

      with subtest("a remote bare repo can be started"):
        githost.succeed("mkdir -p ~/myorg/myapp.git")
        githost.succeed("cd ~/myorg/myapp.git && git init --bare")

      with subtest("a git project can be configured with a remote using ssh"):
        client.succeed("mkdir -p ~/code/myapp")
        client.succeed("cd ~/code/myapp && git init")
        client.succeed("cp ${thunkableSample} ~/code/myapp/default.nix")
        client.succeed("cd ~/code/myapp && git add .")

        client.succeed('cd ~/code/myapp && git commit -m "Initial"')
        client.succeed("cd ~/code/myapp && git remote add origin root@githost:/root/myorg/myapp.git")

      with subtest("pushing code to the remote"):
        client.succeed("cd ~/code/myapp && git push -u origin master")
        client.succeed("cd ~/code/myapp && git status")

      with subtest("nix-thunk can pack and unpack"):
        client.succeed("nix-thunk pack ~/code/myapp")
        client.succeed("grep -qF 'git.json' ~/code/myapp/thunk.nix")
        client.succeed("grep -qF 'myorg' ~/code/myapp/git.json")
        client.succeed("nix-thunk unpack ~/code/myapp")

      with subtest("nix-thunk can create from ssh remote"):
        client.succeed("nix-thunk pack ~/code/myapp")
        client.succeed("nix-thunk create -b master root@githost:/root/myorg/myapp.git ~/code/myapp-remote")
        client.succeed("diff -u ~/code/myapp/git.json ~/code/myapp-remote/git.json")
        client.succeed("cmp ~/code/myapp/git.json ~/code/myapp-remote/git.json")
        client.succeed("nix-thunk unpack ~/code/myapp; nix-thunk unpack ~/code/myapp-remote")

      with subtest("nix-thunk can create from local directory"):
        client.succeed("nix-thunk create ~/code/myapp ~/code/myapp-local")
        client.succeed("nix-thunk unpack ~/code/myapp-local")

      with subtest("unpacked thunks can be built"):
        client.succeed("nix-build ~/code/myapp")
        client.succeed("nix-build ~/code/myapp-remote")
        client.succeed("nix-build ~/code/myapp-local")

      with subtest("packed thunks can be built"):
        client.succeed("nix-thunk -v pack ~/code/myapp-remote; nix-thunk -v pack ~/code/myapp-local")
        client.succeed("nix-build ~/code/myapp-remote")
        client.succeed("nix-build ~/code/myapp-local")
        client.succeed("nix-thunk unpack ~/code/myapp-remote")

      with subtest("nix-thunk can update from ssh remote"):
        client.succeed("""
          cd ~/code/myapp;
          touch test-file;
          git add test-file;
          git commit test-file -m "add test file";
          git push;
        """)
        client.succeed("nix-thunk pack ~/code/myapp-remote")
        client.succeed("nix-thunk update ~/code/myapp-remote")
        client.succeed("nix-thunk unpack ~/code/myapp-remote")
        client.succeed("test -f ~/code/myapp-remote/test-file")

      with subtest("nix-thunk can update from local directory"):
        client.succeed("nix-thunk update ~/code/myapp-local")
        client.succeed("nix-thunk unpack ~/code/myapp-local")
        client.succeed("test -f ~/code/myapp-local/test-file")

      # This test is a bit... dirty. We can't create the thunk on
      # 'noNixThunk', that's the whole point. We can't create the thunk
      # in this nix file, because [mumble] nix-prefetch-git doesn't work
      # inside the sandbox. But you know what we *can* do? Move the
      # thunk from one machine to the other. And since we already have
      # Git...
      with subtest("packed thunks can be built without nix-thunk"):
        client.succeed("""
          nix-thunk pack ~/code/myapp-remote;
          rsync -avx ~/code/myapp-remote githost:
        """)
        noNixThunk.succeed("""
          rsync -avx githost:myapp-remote .;
          nix-build myapp-remote
        """)
      '';
  }) {}
