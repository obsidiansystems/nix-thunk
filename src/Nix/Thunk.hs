module Nix.Thunk
  ( ThunkSource (..)
  , GitHubSource (..)
  , ThunkRev (..)
  , getLatestRev
  , gitCloneForThunkUnpack
  , thunkSourceToGitSource
  , ThunkPtr (..)
  , ThunkData (..)
  , readThunk
  , CheckClean (..)
  , getThunkPtr
  , packThunk
  , createThunk
  , createThunk'
  , createWorktree
  , CreateWorktreeConfig (..)
  , ThunkPackConfig (..)
  , ThunkConfig (..)
  , updateThunkToLatest
  , updateThunk
  , ThunkUpdateConfig (..)
  , unpackThunk
  , ThunkSpec (..)
  , ThunkFileSpec (..)
  , NixThunkError
  , nixBuildAttrWithCache
  , attrCacheFileName
  , prettyNixThunkError
  , ThunkCreateSource (..)
  , ThunkCreateConfig (..)
  , parseGitUri
  , GitUri (..)
  , uriThunkPtr
  , Ref(..)
  , refFromHexString
  ) where

import Nix.Thunk.Internal
