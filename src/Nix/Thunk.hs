{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
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
