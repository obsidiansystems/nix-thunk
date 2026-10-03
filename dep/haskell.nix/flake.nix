# DO NOT HAND-EDIT THIS FILE
{
  inputs = {
    "upstream" = {
      owner = "input-output-hk";
      repo = "haskell.nix";
      rev = "07e888ef7c26b62c4f2a843ed305c6e09b0a6828";
      type = "github";
      inputs = {
        "HTTP" = { follows = "HTTP"; };
        "cabal-34" = { follows = "cabal-34"; };
        "cabal-36" = { follows = "cabal-36"; };
        "cardano-shell" = { follows = "cardano-shell"; };
        "flake-compat" = { follows = "flake-compat"; };
        "hackage" = { follows = "hackage"; };
        "hackage-for-stackage" = { follows = "hackage-for-stackage"; };
        "hackage-internal" = { follows = "hackage-internal"; };
        "hls" = { follows = "hls"; };
        "hls-1.10" = { follows = "hls-1_10"; };
        "hls-2.0" = { follows = "hls-2_0"; };
        "hls-2.10" = { follows = "hls-2_10"; };
        "hls-2.11" = { follows = "hls-2_11"; };
        "hls-2.12" = { follows = "hls-2_12"; };
        "hls-2.2" = { follows = "hls-2_2"; };
        "hls-2.3" = { follows = "hls-2_3"; };
        "hls-2.4" = { follows = "hls-2_4"; };
        "hls-2.5" = { follows = "hls-2_5"; };
        "hls-2.6" = { follows = "hls-2_6"; };
        "hls-2.7" = { follows = "hls-2_7"; };
        "hls-2.8" = { follows = "hls-2_8"; };
        "hls-2.9" = { follows = "hls-2_9"; };
        "hpc-coveralls" = { follows = "hpc-coveralls"; };
        "iserv-proxy" = { follows = "iserv-proxy"; };
        "nixpkgs" = { follows = "nixpkgs"; };
        "nixpkgs-2305" = { follows = "nixpkgs-2305"; };
        "nixpkgs-2311" = { follows = "nixpkgs-2311"; };
        "nixpkgs-2405" = { follows = "nixpkgs-2405"; };
        "nixpkgs-2411" = { follows = "nixpkgs-2411"; };
        "nixpkgs-2505" = { follows = "nixpkgs-2505"; };
        "nixpkgs-2511" = { follows = "nixpkgs-2511"; };
        "nixpkgs-unstable" = { follows = "nixpkgs"; };
        "old-ghc-nix" = { follows = "old-ghc-nix"; };
        "stackage" = { follows = "stackage"; };
      };
    };
    "HTTP" = {
      flake = false;
      narHash = "sha256-oHIyw3x0iKBexEo49YeUDV1k74ZtyYKGR2gNJXXRxts=";
      owner = "phadej";
      repo = "HTTP";
      rev = "9bc0996d412fef1787449d841277ef663ad9a915";
      type = "github";
    };
    "cabal-34" = {
      flake = false;
      narHash = "sha256-wG3d+dOt14z8+ydz4SL7pwGfe7SiimxcD/LOuPCV6xM=";
      owner = "haskell";
      repo = "cabal";
      rev = "5ff598c67f53f7c4f48e31d722ba37172230c462";
      type = "github";
    };
    "cabal-36" = {
      flake = false;
      narHash = "sha256-I5or+V7LZvMxfbYgZATU4awzkicBwwok4mVoje+sGmU=";
      owner = "haskell";
      repo = "cabal";
      rev = "8fd619e33d34924a94e691c5fea2c42f0fc7f144";
      type = "github";
    };
    "cardano-shell" = {
      flake = false;
      narHash = "sha256-PulY1GfiMgKVnBci3ex4ptk2UNYMXqGjJOxcPy2KYT4=";
      owner = "input-output-hk";
      repo = "cardano-shell";
      rev = "9392c75087cb9a3d453998f4230930dea3a95725";
      type = "github";
    };
    "flake-compat" = {
      flake = false;
      narHash = "sha256-z9k3MfslLjWQfnjBtEtJZdq3H7kyi2kQtUThfTgdRk0=";
      owner = "input-output-hk";
      repo = "flake-compat";
      rev = "45f2638735f8cdc40fe302742b79f248d23eb368";
      type = "github";
    };
    "hackage" = {
      flake = false;
      narHash = "sha256-/6wYc1TziLO7He2nzoCYS/VzIbFxayQjViTTHY2KCsU=";
      owner = "input-output-hk";
      repo = "hackage.nix";
      rev = "d82fc53191254fa3b3a1c23092c260efcd428759";
      type = "github";
    };
    "hackage-for-stackage" = {
      flake = false;
      narHash = "sha256-b834p0ee0EN6S0p/EqywunkgESLY3EQEscPGd4+7So0=";
      owner = "input-output-hk";
      repo = "hackage.nix";
      rev = "87700195b4a495d05a43950f0af50b6d75badeea";
      type = "github";
    };
    "hackage-internal" = {
      flake = false;
      narHash = "sha256-iiafNoeLHwlSLQTyvy8nPe2t6g5AV4PPcpMeH/2/DLs=";
      owner = "input-output-hk";
      repo = "hackage.nix";
      rev = "f7867baa8817fab296528f4a4ec39d1c7c4da4f3";
      type = "github";
    };
    "hls" = {
      flake = false;
      narHash = "sha256-tuq3+Ip70yu89GswZ7DSINBpwRprnWnl6xDYnS4GOsc=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "682d6894c94087da5e566771f25311c47e145359";
      type = "github";
    };
    "hls-1_10" = {
      flake = false;
      narHash = "sha256-rc7iiUAcrHxwRM/s0ErEsSPxOR3u8t7DvFeWlMycWgo=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "b08691db779f7a35ff322b71e72a12f6e3376fd9";
      type = "github";
    };
    "hls-2_0" = {
      flake = false;
      narHash = "sha256-OHXlgRzs/kuJH8q7Sxh507H+0Rb8b7VOiPAjcY9sM1k=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "783905f211ac63edf982dd1889c671653327e441";
      type = "github";
    };
    "hls-2_10" = {
      flake = false;
      narHash = "sha256-q4kDFyJDDeoGqfEtrZRx4iqMVEC2MOzCToWsFY+TOzY=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "2318c61db3a01e03700bd4b05665662929b7fe8b";
      type = "github";
    };
    "hls-2_11" = {
      flake = false;
      narHash = "sha256-/MmtpF8+FyQlwfKHqHK05BdsxC9LHV70d/FiMM7pzBM=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "46ef4523ea4949f47f6d2752476239f1c6d806fe";
      type = "github";
    };
    "hls-2_12" = {
      flake = false;
      narHash = "sha256-xkI8MIIVEVARskfWbGAgP5sHG/lyeKnkm0LIOJ19X5w=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "7d983de4fa7ff54369f6dd31444bdb9869aec83e";
      type = "github";
    };
    "hls-2_2" = {
      flake = false;
      narHash = "sha256-8DGIyz5GjuCFmohY6Fa79hHA/p1iIqubfJUTGQElbNk=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "b30f4b6cf5822f3112c35d14a0cba51f3fe23b85";
      type = "github";
    };
    "hls-2_3" = {
      flake = false;
      narHash = "sha256-tR58doOs3DncFehHwCLczJgntyG/zlsSd7DgDgMPOkI=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "458ccdb55c9ea22cd5d13ec3051aaefb295321be";
      type = "github";
    };
    "hls-2_4" = {
      flake = false;
      narHash = "sha256-YHXSkdz53zd0fYGIYOgLt6HrA0eaRJi9mXVqDgmvrjk=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "54507ef7e85fa8e9d0eb9a669832a3287ffccd57";
      type = "github";
    };
    "hls-2_5" = {
      flake = false;
      narHash = "sha256-fyiR9TaHGJIIR0UmcCb73Xv9TJq3ht2ioxQ2mT7kVdc=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "27f8c3d3892e38edaef5bea3870161815c4d014c";
      type = "github";
    };
    "hls-2_6" = {
      flake = false;
      narHash = "sha256-+P87oLdlPyMw8Mgoul7HMWdEvWP/fNlo8jyNtwME8E8=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "6e0b342fa0327e628610f2711f8c3e4eaaa08b1e";
      type = "github";
    };
    "hls-2_7" = {
      flake = false;
      narHash = "sha256-LfJ+TBcBFq/XKoiNI7pc4VoHg4WmuzsFxYJ3Fu+Jf+M=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "50322b0a4aefb27adc5ec42f5055aaa8f8e38001";
      type = "github";
    };
    "hls-2_8" = {
      flake = false;
      narHash = "sha256-Vi/iUt2pWyUJlo9VrYgTcbRviWE0cFO6rmGi9rmALw0=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "dd1be1beb16700de59e0d6801957290bcf956a0a";
      type = "github";
    };
    "hls-2_9" = {
      flake = false;
      narHash = "sha256-wy348++MiMm/xwtI9M3vVpqj2qfGgnDcZIGXw8sF1sA=";
      owner = "haskell";
      repo = "haskell-language-server";
      rev = "90319a7e62ab93ab65a95f8f2bcf537e34dae76a";
      type = "github";
    };
    "hpc-coveralls" = {
      flake = false;
      narHash = "sha256-8uqsEtivphgZWYeUo5RDUhp6bO9j2vaaProQxHBltQk=";
      owner = "sevanspowell";
      repo = "hpc-coveralls";
      rev = "14df0f7d229f4cd2e79f8eabb1a740097fdfa430";
      type = "github";
    };
    "iserv-proxy" = {
      flake = false;
      narHash = "sha256-10x8/G0x3eR/++XRHPx4MBuqlnc6+N+ajIxXyLkG+nU=";
      owner = "stable-haskell";
      repo = "iserv-proxy";
      rev = "3f7b2815307c20a0dfd816bdf4a39ab86af3e0d4";
      type = "github";
    };
    "nixpkgs" = {
      narHash = "sha256-nwASzrRDD1JBEu/o8ekKYEXm/oJW6EMCzCRdrwcLe90=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "13043924aaa7375ce482ebe2494338e058282925";
      type = "github";
    };
    "nixpkgs-2305" = {
      narHash = "sha256-K5eJHmL1/kev6WuqyqqbS1cdNnSidIZ3jeqJ7GbrYnQ=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "a1982c92d8980a0114372973cbdfe0a307f1bdea";
      type = "github";
    };
    "nixpkgs-2311" = {
      narHash = "sha256-gvFhEf5nszouwLAkT9nWsDzocUTqLWHuL++dvNjMp9I=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "7144d6241f02d171d25fba3edeaf15e0f2592105";
      type = "github";
    };
    "nixpkgs-2405" = {
      narHash = "sha256-HB/FA0+1gpSs8+/boEavrGJH+Eq08/R2wWNph1sM1Dg=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "1e7a8f391f1a490460760065fa0630b5520f9cf8";
      type = "github";
    };
    "nixpkgs-2411" = {
      narHash = "sha256-kNf+obkpJZWar7HZymXZbW+Rlk3HTEIMlpc6FCNz0Ds=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "5ab036a8d97cb9476fbe81b09076e6e91d15e1b6";
      type = "github";
    };
    "nixpkgs-2505" = {
      narHash = "sha256-M5aFEFPppI4UhdOxwdmceJ9bDJC4T6C6CzCK1E2FZyo=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "6c8f0cca84510cc79e09ea99a299c9bc17d03cb6";
      type = "github";
    };
    "nixpkgs-2511" = {
      narHash = "sha256-msT6frWJSQ2WR+0cpk+KPcZdLTLagUIsJwQwIX9JNSo=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "74b87959b2d16f59f54d8559cf3cf26b9d907949";
      type = "github";
    };
    "nixpkgs-unstable" = {
      follows = "nixpkgs";
    };
    "old-ghc-nix" = {
      flake = false;
      narHash = "sha256-sIKgO+z7tj4lw3u6oBZxqIhDrzSkvpHtv0Kki+lh9Fg=";
      owner = "angerman";
      repo = "old-ghc-nix";
      rev = "af48a7a7353e418119b6dfe3cd1463a657f342b8";
      type = "github";
    };
    "stackage" = {
      flake = false;
      narHash = "sha256-IOeW4ljAEAjfKsb/Z/sqEhoIoD3Dt82g1X+6AiAhuww=";
      owner = "input-output-hk";
      repo = "stackage.nix";
      rev = "fafdcebafc53c484df67f80166c0266eb7316b27";
      type = "github";
    };
  };
  outputs = inputs: inputs."upstream".outputs // { src = inputs."upstream"; };
}
