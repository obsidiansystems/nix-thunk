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
        client.succeed("""
          nix-thunk --help;
          git config --global user.email "you@example.com";
          git config --global user.name "Your Name";
        """)

      githost.wait_for_open_port("22")

      with subtest("the clients can access the server via ssh"):
        for machine in [client, noNixThunk]:
          machine.succeed("""
            mkdir -p ~/.ssh/;
            cp ${privateKeyFile} ~/.ssh/id_rsa;
            chmod 600 ~/.ssh/id_rsa;
          """)
          machine.wait_until_succeeds(
            "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa githost true"
          )
          machine.succeed("cp ${sshConfigFile} ~/.ssh/config")
          machine.wait_until_succeeds("ssh githost true")

      with subtest("a remote bare repo can be started"):
        githost.succeed("""
          mkdir -p ~/myorg/myapp.git;
          cd ~/myorg/myapp.git && git init --bare
        """)

      with subtest("a git project can be configured with a remote using ssh"):
        client.succeed("""
          mkdir -p ~/code/myapp;
          cd ~/code/myapp;
          git init;
          cp ${thunkableSample} default.nix;
          git add .;
          git commit -m 'Initial';
          git remote add origin root@githost:/root/myorg/myapp.git;
        """)

      with subtest("pushing code to the remote"):
        client.succeed("""
          cd ~/code/myapp;
          git push -u origin master;
          git status;
        """)

      with subtest("nix-thunk can pack and unpack"):
        client.succeed("""
          nix-thunk pack ~/code/myapp;
          grep -qF 'git.json' ~/code/myapp/thunk.nix;
          grep -qF 'myorg' ~/code/myapp/git.json;
          nix-thunk unpack ~/code/myapp;
        """)

      with subtest("nix-thunk can create from ssh remote"):
        client.succeed("""
          nix-thunk pack ~/code/myapp;
          nix-thunk create -b master root@githost:/root/myorg/myapp.git ~/code/myapp-remote;
          diff -u ~/code/myapp/git.json ~/code/myapp-remote/git.json;
          cmp ~/code/myapp/git.json ~/code/myapp-remote/git.json;
          nix-thunk unpack ~/code/myapp;
          nix-thunk unpack ~/code/myapp-remote;
        """)

      with subtest("nix-thunk can create from local directory"):
        client.succeed("""
          nix-thunk create ~/code/myapp ~/code/myapp-local
          nix-thunk unpack ~/code/myapp-local
        """)

      with subtest("unpacked thunks can be built"):
        client.succeed("""
          nix-build ~/code/myapp;
          nix-build ~/code/myapp-remote;
          nix-build ~/code/myapp-local;
        """)

      with subtest("packed thunks can be built"):
        client.succeed("""
          nix-thunk -v pack ~/code/myapp-remote;
          nix-thunk -v pack ~/code/myapp-local;
          nix-build ~/code/myapp-remote;
          nix-build ~/code/myapp-local;
          nix-thunk unpack ~/code/myapp-remote;
        """)

      with subtest("nix-thunk can update from ssh remote"):
        client.succeed("""
          cd ~/code/myapp;
          touch test-file;
          git add test-file;
          git commit test-file -m "add test file";
          git push;

          nix-thunk pack ~/code/myapp-remote;
          nix-thunk update ~/code/myapp-remote;
          nix-thunk unpack ~/code/myapp-remote;
          test -f ~/code/myapp-remote/test-file;
        """)

      with subtest("nix-thunk can update from local directory"):
        client.succeed("""
          nix-thunk update ~/code/myapp-local;
          nix-thunk unpack ~/code/myapp-local;
          test -f ~/code/myapp-local/test-file;
        """)

      with subtest("nix-thunk pack will not destroy changes"):
        client.succeed("""
          cd ~/code/myapp-local;
          echo "# Some change" >> default.nix;
          nix-build
        """);
        client.fail("nix-thunk pack ~/code/myapp-local;")

      with subtest("packed thunks can be built without nix-thunk"):
        client.succeed("""
          nix-thunk pack ~/code/myapp-remote;
          rsync -avx ~/code/myapp-remote githost:
        """)
        noNixThunk.succeed("""
          rsync -avx githost:myapp-remote .;
          nix-build myapp-remote
        """)

      with subtest("nix-thunk informs the user about parse errors"):
        client.fail("""
          touch ~/code/myapp-remote/extra-file;
          nix-thunk unpack ~/code/myapp-remote 2>parse-error
        """)
        client.succeed("grep 'extra-file' parse-error")

      with subtest("nix-thunk can create from ssh remote, with branch.master.merge set"):
        client.succeed("""
          git config --global branch.master.merge master;
          nix-thunk pack ~/code/myapp;
          nix-thunk create -b master root@githost:/root/myorg/myapp.git ~/code/myapp-remote-merge-master;
          diff -u ~/code/myapp/git.json ~/code/myapp-remote-merge-master/git.json;
          cmp ~/code/myapp/git.json ~/code/myapp-remote-merge-master/git.json;
          nix-thunk unpack ~/code/myapp
        """)

      with subtest("can create worktree using existing repo, doing detached HEAD when no branch is specified in thunk"):
        client.succeed("""
          nix-thunk create root@githost:/root/myorg/myapp.git ~/code/myapp-2;
          git clone root@githost:/root/myorg/myapp.git ~/code/myapp-mainrepo;
          nix-thunk worktree ~/code/myapp-2 ~/code/myapp-mainrepo;
        """);

      with subtest("gives error when packing worktree on detached HEAD"):
        client.fail("""
          nix-thunk pack ~/code/myapp-2;
        """)

      with subtest("can pack worktree with branch specified, and removes the local branch after packing"):
        client.succeed("""
          git -C ~/code/myapp-mainrepo checkout -b temp-branch;
          git -C ~/code/myapp-2 checkout master;
          nix-thunk pack ~/code/myapp-2;
        """);
        client.fail("""
          git -C ~/code/myapp-mainrepo rev-parse --verify master;
        """)

      with subtest("can create worktree, and checkout the default branch"):
        client.succeed("""
          nix-thunk worktree ~/code/myapp-2 ~/code/myapp-mainrepo;
          git -C ~/code/myapp-mainrepo rev-parse --verify master;
        """);

      with subtest("fails if the branch is already checked out"):
        client.succeed("""
          git -C ~/code/myapp-2 branch --set-upstream-to origin/master;
          nix-thunk pack ~/code/myapp-2;
          git -C ~/code/myapp-mainrepo checkout -b master;
        """);
        client.fail("""
          nix-thunk worktree ~/code/myapp-2 ~/code/myapp-mainrepo;
        """);

      with subtest("can create worktree, when a new branch is specified"):
        client.succeed("""
          nix-thunk worktree ~/code/myapp-2 ~/code/myapp-mainrepo -b somebranch-2;
          git -C ~/code/myapp-mainrepo rev-parse --verify somebranch-2;
        """);

      with subtest("fails when packing worktree with unpushed branch"):
        client.fail("""
          nix-thunk pack ~/code/myapp-2; # has somebranch-2 checked out
        """)

      with subtest("can pack worktree having unpushed branches"):
        client.succeed("""
          git -C ~/code/myapp-mainrepo checkout temp-branch;
          git -C ~/code/myapp-2 checkout master; # repo still contains somebranch-2, having no remote
          git -C ~/code/myapp-2 branch --set-upstream-to origin/master;
          nix-thunk pack ~/code/myapp-2;
        """)

      with subtest("fails to pack worktree containing modifications"):
        client.succeed("""
          nix-thunk worktree ~/code/myapp-2 ~/code/myapp-mainrepo;
          touch ~/code/myapp-2/extra-file;
        """)
        client.fail("""
          nix-thunk pack ~/code/myapp-2;
        """)

      with subtest("can pack worktree with stashed changes"):
        client.succeed("""
          git -C ~/code/myapp-2 add extra-file;
          git -C ~/code/myapp-2 stash;
          git -C ~/code/myapp-2 branch --set-upstream-to origin/master;
          nix-thunk pack ~/code/myapp-2;
        """)
      '';
  }) {}
