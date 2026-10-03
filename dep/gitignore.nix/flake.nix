# DO NOT HAND-EDIT THIS FILE
{
  inputs = {
    "upstream" = {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "a20de23b925fd8264fd7fad6454652e142fd7f73";
      type = "github";
      inputs = {
        "nixpkgs" = { follows = "nixpkgs"; };
      };
    };
    "nixpkgs" = {
      narHash = "sha256-sFi6YtlGK30TBB9o6CW7LG9mYHkgtKeWbSLAjjrNTX0=";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "2b71ddd869ad592510553d09fe89c9709fa26b2b";
      type = "github";
    };
  };
  outputs = inputs: inputs."upstream".outputs // { src = inputs."upstream"; };
}
