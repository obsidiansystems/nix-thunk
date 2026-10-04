# Resolve a nix-thunk directory to its source. Equivalent to nix-thunk's
# thunkSource. The directory has two states:
# - Packed: it holds github.json and thunk.nix. Importing thunk.nix fetches
#   the pin.
# - Unpacked: it is a checkout of the dependency itself, used directly.
#
# Example:
#
#   import ./thunk.nix ./dep/reflex-dom   # packed
#   => <the fetched source of the pin>
#
#   import ./thunk.nix ./dep/checkout     # unpacked
#   => ./dep/checkout
path:
if builtins.pathExists (path + "/thunk.nix")
then import (path + "/thunk.nix")
else path
