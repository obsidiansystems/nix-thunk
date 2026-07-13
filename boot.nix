# This is a tentative public interface.
#
# We may decide to stablize it, but for now it is still UNSTABLE.

let
  inherit (import ./private.nix)
    contentsMatch
    isThunkWithThunkNix
    ;

in {
  # This only works with newer thunks, and is intended for the
  # bootstrapping usecase where:
  #
  #  - We don't yet have a `lib,` `pkgs`, or `gitignoreSource`
  #
  #  - We just need the repo in question for Nix code, and not source
  #  files to copy to the store.
  thunkSourceNoFilter = p:
    let
      contents = builtins.readDir p;
    in if isThunkWithThunkNix contents then import (p + "/thunk.nix")
    else p;
}
