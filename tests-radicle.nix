# Radicle-specific tests for nix-thunk
# These tests require a newer nixpkgs that includes the radicle package.
{ command # The nix-thunk command to test
, packedThunkNixpkgs # The nixpkgs that nix-thunk uses
}:
let
  # Use a recent nixpkgs that includes radicle-node and services.radicle
  # nixos-24.11 or later should have radicle support
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
    sha256 = "1s2gr5rcyqvpr58vxdcb095mdhblij9bfzaximrva2243aal3dgx";
  }) {};
  make-test = import (pkgs.path + /nixos/tests/make-test-python.nix);

  thunkableSample = pkgs.writeText "default.nix" ''
    let pkgs = import <nixpkgs> {}; in pkgs.git
  '';
in
  make-test ({...}: {
    name = "nix-thunk-radicle";

    nodes = {
      # Single radicle node that acts as both the "seed" and the client
      radicle = {
        imports = [ (pkgs.path + /nixos/modules/installer/cd-dvd/channel.nix) ];

        # Radicle node needs networking
        networking.firewall.allowedTCPPorts = [ 8776 ]; # radicle default port

        # Disable sandbox for nix builds in the test
        nix.settings.sandbox = false;
        nix.settings.substituters = [];

        environment.systemPackages = [
          pkgs.radicle-node
          pkgs.git
          pkgs.nix-prefetch-git

          command

          # nixpkgs for building thunks
          packedThunkNixpkgs
        ];
      };
    };

    testScript =
      let
      in ''
      start_all()

      radicle.wait_for_unit("multi-user.target")

      with subtest("radicle and nix-thunk are installed"):
        radicle.succeed("rad --version")
        radicle.succeed("nix-thunk --help")

      with subtest("git can be configured"):
        radicle.succeed("""
          git config --global user.email "test@example.com"
          git config --global user.name "Test User"
          git config --global init.defaultBranch master
        """)

      with subtest("rad auth creates a radicle identity"):
        # Create radicle identity (non-interactive with RAD_PASSPHRASE)
        radicle.succeed("""
          RAD_PASSPHRASE="" rad auth --alias testnode
        """)

      with subtest("create a local git repository"):
        radicle.succeed("""
          mkdir -p ~/code/myproject
          cd ~/code/myproject
          git init
          cp ${thunkableSample} default.nix
          git add default.nix
          git commit -m "Initial commit"
        """)

      with subtest("initialize radicle repository"):
        # Initialize the repo as a radicle project
        radicle.succeed("""
          cd ~/code/myproject
          rad init --name myproject --description "Test project" --default-branch master --public
        """)

      with subtest("get the radicle RID"):
        # Get the repository ID (RID)
        rid = radicle.succeed("cd ~/code/myproject && rad inspect --rid").strip()
        print(f"Repository RID: {rid}")

      with subtest("nix-thunk can pack a radicle repository"):
        radicle.succeed("""
          cd ~/code/myproject
          # Ensure we're on a tracked branch for packing
          git branch --set-upstream-to=rad/master master || true
          cd ~
          nix-thunk pack ~/code/myproject
        """)
        # Verify the thunk contains radicle URL
        radicle.succeed("grep -q 'rad://' ~/code/myproject/git.json")

      with subtest("nix-thunk can unpack a radicle thunk"):
        radicle.succeed("""
          nix-thunk unpack ~/code/myproject
          test -f ~/code/myproject/default.nix
        """)
      '';
  }) {}
