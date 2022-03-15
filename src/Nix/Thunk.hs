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
  , ThunkPackConfig (..)
  , ThunkConfig (..)
  , updateThunkToLatest
  , ThunkUpdateConfig (..)
  , unpackThunk
  , ThunkSpec (..)
  , ThunkFileSpec (..)
  , NixThunkError
  , nixBuildAttrWithCache
  , attrCacheFileName
  , prettyNixThunkError
  , ThunkCreateConfig (..)
  , parseGitUri
  , GitUri (..)
  , uriThunkPtr
  , Ref(..)
  , refFromHexString
  ) where

import Nix.Thunk.Internal

