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
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
module Nix.Thunk.Internal where

import Bindings.Cli.Coreutils (cp)
import Bindings.Cli.Git
    ( ensureCleanGitRepo,
      gitLookupCommitForRef,
      gitLookupDefaultBranch,
      gitLsRemote,
      gitProc,
      gitProcNoRepo,
      isolateGitProc,
      CommitId,
      GitRef(GitRef_Branch) )
import Bindings.Cli.Nix
import Cli.Extras
import Control.Applicative
import Control.Exception (Exception, displayException, throw, try)
import Control.Lens ((.~), ifor, ifor_, makePrisms)
import Control.Monad
import Control.Monad.Catch (MonadCatch, MonadMask, handle)
import Control.Monad.Except
import Control.Monad.Extra (findM)
import Control.Monad.Fail (MonadFail)
import Control.Monad.Log (MonadLog)
import Crypto.Hash (Digest, HashAlgorithm, SHA1, digestFromByteString)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Encode.Pretty
import qualified Data.Aeson.Types as Aeson
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base(..), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Containers.ListUtils (nubOrd)
import Data.Data (Data)
import Data.Default
import Data.Either.Combinators (fromRight', rightToMaybe)
import Data.Foldable (for_, toList)
import Data.Function
import qualified Data.List as L
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String.Here.Interpolated (i)
import Data.String.Here.Uninterpolated (here)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import qualified Data.Text.IO as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Traversable
import Data.Typeable (Typeable)
import Data.Yaml (parseMaybe)
import GitHub
import GitHub.Data.Name
import System.Directory
import System.Environment (getArgs)
import System.Exit
import System.FilePath
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp
import System.Posix.Files
import qualified Text.URI as URI

--------------------------------------------------------------------------------
-- Hacks
--------------------------------------------------------------------------------

type MonadInfallibleNixThunk m =
  ( CliLog m
  , HasCliConfig NixThunkError m
  , MonadIO m
  , MonadMask m
  )

type MonadNixThunk m =
  ( MonadInfallibleNixThunk m
  , CliThrow NixThunkError m
  , MonadFail m
  )

-- | Runs MonadNixThunk actions with relatively sensible options for non-interactive use.
runMonadNixThunk :: forall a. (forall m. MonadNixThunk m => m a) -> IO a
runMonadNixThunk x = do
  cliConf <- newCliConfig Error False False (\e -> (prettyNixThunkError e, ExitFailure 1))
  runCli cliConf x

data NixThunkError
   = NixThunkError_ProcessFailure ProcessFailure
   | NixThunkError_Unstructured Text

prettyNixThunkError :: NixThunkError -> Text
prettyNixThunkError = \case
  NixThunkError_ProcessFailure (ProcessFailure p code) ->
    "Process exited with code " <> T.pack (show code) <> "; " <> reconstructCommand p
  NixThunkError_Unstructured msg -> msg

makePrisms ''NixThunkError

instance AsUnstructuredError NixThunkError where
  asUnstructuredError = _NixThunkError_Unstructured

instance AsProcessFailure NixThunkError where
  asProcessFailure = _NixThunkError_ProcessFailure

--------------------------------------------------------------------------------
-- End hacks
--------------------------------------------------------------------------------

--TODO: Support symlinked thunk data
data ThunkData
   = ThunkData_Packed ThunkSpec ThunkPtr
   -- ^ Packed thunk
   | ThunkData_Checkout
   -- ^ Checked out thunk that was unpacked from this pointer

-- | A reference to the exact data that a thunk should translate into
data ThunkPtr = ThunkPtr
  { _thunkPtr_rev :: ThunkRev
  , _thunkPtr_source :: ThunkSource
  }
  deriving (Show, Eq, Ord)

type NixSha256 = Text --TODO: Use a smart constructor and make this actually verify itself

-- | A specific revision of data; it may be available from multiple sources
data ThunkRev = ThunkRev
  { _thunkRev_commit :: Ref SHA1
  , _thunkRev_nixSha256 :: NixSha256
  }
  deriving (Show, Eq, Ord)

-- | A location from which a thunk's data can be retrieved
data ThunkSource
   -- | A source specialized for GitHub
   = ThunkSource_GitHub GitHubSource
   -- | A plain repo source
   | ThunkSource_Git GitSource
   deriving (Show, Eq, Ord)

thunkSourceToGitSource :: ThunkSource -> GitSource
thunkSourceToGitSource = \case
  ThunkSource_GitHub s -> forgetGithub False s
  ThunkSource_Git s -> s

data GitHubSource = GitHubSource
  { _gitHubSource_owner :: Name Owner
  , _gitHubSource_repo :: Name Repo
  , _gitHubSource_branch :: Maybe (Name Branch)
  , _gitHubSource_private :: Bool
  }
  deriving (Show, Eq, Ord)

newtype GitUri = GitUri { unGitUri :: URI.URI } deriving (Eq, Ord, Show)

gitUriToText :: GitUri -> Text
gitUriToText (GitUri uri)
  | (T.toLower . URI.unRText <$> URI.uriScheme uri) == Just "file"
  , Just (_, path) <- URI.uriPath uri
  = "/" <> T.intercalate "/" (map URI.unRText $ NonEmpty.toList path)
  | otherwise = URI.render uri

data GitSource = GitSource
  { _gitSource_url :: GitUri
  , _gitSource_branch :: Maybe (Name Branch)
  , _gitSource_fetchSubmodules :: Bool
  , _gitSource_private :: Bool
  }
  deriving (Show, Eq, Ord)

newtype ThunkConfig = ThunkConfig
  { _thunkConfig_private :: Maybe Bool
  } deriving Show

data ThunkUpdateConfig = ThunkUpdateConfig
  { _thunkUpdateConfig_branch :: Maybe String
  , _thunkUpdateConfig_config :: ThunkConfig
  } deriving Show

data ThunkPackConfig = ThunkPackConfig
  { _thunkPackConfig_force :: Bool
  , _thunkPackConfig_config :: ThunkConfig
  } deriving Show

-- | The source to be used for creating thunks.
data ThunkCreateSource
  = ThunkCreateSource_Absolute GitUri
    -- ^ Create a thunk from an absolute reference to a Git repository:
    -- URIs like @file://@, @https://@, @ssh://@ etc.
  | ThunkCreateSource_Relative FilePath
    -- ^ Create a thunk from a local folder. If the folder exists, then
    -- it is made absolute using the current working directory and
    -- treated as a @file://@ URL.
  deriving Show

data ThunkCreateConfig = ThunkCreateConfig
  { _thunkCreateConfig_uri         :: ThunkCreateSource
  , _thunkCreateConfig_branch      :: Maybe (Name Branch)
  , _thunkCreateConfig_rev         :: Maybe (Ref SHA1)
  , _thunkCreateConfig_config      :: ThunkConfig
  , _thunkCreateConfig_destination :: Maybe FilePath
  } deriving Show

-- | Convert a GitHub source to a regular Git source. Assumes no submodules.
forgetGithub :: Bool -> GitHubSource -> GitSource
forgetGithub useSsh s = GitSource
  { _gitSource_url = GitUri $ URI.URI
    { URI.uriScheme = Just $ fromRight' $ URI.mkScheme $ if useSsh then "ssh" else "https"
    , URI.uriAuthority = Right $ URI.Authority
        { URI.authUserInfo = URI.UserInfo (fromRight' $ URI.mkUsername "git") Nothing
          <$ guard useSsh
        , URI.authHost = fromRight' $ URI.mkHost "github.com"
        , URI.authPort = Nothing
        }
    , URI.uriPath = Just ( False
                     , fromRight' . URI.mkPathPiece <$>
                       untagName (_gitHubSource_owner s)
                       :| [ untagName (_gitHubSource_repo s) <> ".git" ]
                     )
    , URI.uriQuery = []
    , URI.uriFragment = Nothing
    }
  , _gitSource_branch = _gitHubSource_branch s
  , _gitSource_fetchSubmodules = False
  , _gitSource_private = _gitHubSource_private s
  }

commitNameToRef :: Name Commit -> Ref SHA1
commitNameToRef (N c) = refFromHex $ encodeUtf8 c

-- TODO: Use spinner here.
getNixSha256ForUriUnpacked
  :: MonadNixThunk m
  => GitUri
  -> m NixSha256
getNixSha256ForUriUnpacked uri =
  withExitFailMessage ("nix-prefetch-url: Failed to determine sha256 hash of URL " <> gitUriToText uri) $ do
    [hash] <- fmap T.lines $ readProcessAndLogOutput (Debug, Debug) $
      proc nixPrefetchUrlPath ["--unpack", "--type", "sha256", T.unpack $ gitUriToText uri]
    pure hash

nixPrefetchGit :: MonadNixThunk m => GitUri -> Text -> Bool -> m NixSha256
nixPrefetchGit uri rev fetchSubmodules =
  withExitFailMessage ("nix-prefetch-git: Failed to determine sha256 hash of Git repo " <> gitUriToText uri <> " at " <> rev) $ do
    out <- readProcessAndLogStderr Debug $ ignoreGitConfig $
      proc nixPrefetchGitPath $ filter (/="")
        [ "--url", T.unpack $ gitUriToText uri
        , "--rev", T.unpack rev
        , if fetchSubmodules then "--fetch-submodules" else ""
        , "--quiet"
        ]

    case parseMaybe (Aeson..: "sha256") =<< Aeson.decodeStrict (encodeUtf8 out) of
      Nothing -> failWith $ "nix-prefetch-git: unrecognized output " <> out
      Just x -> pure x

data ReadThunkError
  = ReadThunkError_UnrecognizedThunk
  -- ^ A generic error that can happen while reading a thunk.
  | ReadThunkError_UnrecognizedPaths (Maybe ThunkSpec) (NonEmpty FilePath)
  -- ^ The thunk directory has extraneous paths. The 'Maybe' value
  -- indicates whether we have matched the rest of the files to a valid
  -- specification, and if so, which specification it was.
  | ReadThunkError_MissingPaths (NonEmpty FilePath)
  -- ^ The thunk directory has missing paths.
  | ReadThunkError_UnparseablePtr FilePath String
  -- ^ We could not parse the given file as per the thunk specification.
  -- The 'String' is a parser-specific error message.
  | ReadThunkError_FileError FilePath IOError
  -- ^ We encountered an 'IOError' while reading the given file.
  | ReadThunkError_FileDoesNotMatch FilePath Text
  -- ^ We read the given file just fine, but its contents do not match
  -- what was expected for the specification.
  | ReadThunkError_AmbiguousPackedState ThunkSpec ThunkSpec
  -- ^ We parsed two valid thunk specs for this directory.

-- | Pretty-print a 'ReadThunkError' for display to the user
prettyReadThunkError :: ReadThunkError -> Text
prettyReadThunkError =
  \case
    ReadThunkError_UnrecognizedPaths (Just spec) (f :| fs) ->
      -- Limit to five unrecognised paths so that the user doesn't get
      -- utterly spammed:
      T.unlines ( "The directory matched spec " <> _thunkSpec_name spec <> ", but the following file(s) are extraneous:"
                : map (("  " <>) . T.pack) (f:take 4 fs))
      <> if length fs > 5 then "... and " <> T.pack (show (length fs - 4)) <> " others." else mempty

    ReadThunkError_MissingPaths (f :| fs) ->
      T.unlines $ "The following path(s) are missing from the thunk directory:"
        :map (("  " <>) . T.pack) (f:fs)

    ReadThunkError_FileError path ioe -> "I/O error while reading the file " <> T.pack path <> ":\n" <> T.pack (show ioe)
    ReadThunkError_UnparseablePtr path str -> "Syntax error while reading the file " <> T.pack path <> ":\n" <> T.pack str
    ReadThunkError_FileDoesNotMatch path _ -> "The file " <> T.pack path <> " does not have the right contents for this thunk specification."
    ReadThunkError_AmbiguousPackedState speca specb ->
      "The given thunk directory is ambiguous: It matches both " <> _thunkSpec_name speca <> " and " <> _thunkSpec_name specb <> "."

    ReadThunkError_UnrecognizedThunk -> generic
    ReadThunkError_UnrecognizedPaths{} -> generic
  where
    generic = T.pack "The directory did not match any valid thunk specification.\nRun with -v to see why each spec did not match."

-- | Fail due to a 'ReadThunkError' with a standardised error message.
failReadThunkErrorWhile
  :: MonadError NixThunkError m
  => Text
  -- ^ String describing what we were doing.
  -> ReadThunkError -- ^ The error
  -> m a
failReadThunkErrorWhile what rte = failWith $ "Failure reading thunk " <> what <> ":\n" <> prettyReadThunkError rte

-- | Did we manage to match the thunk directory to one or more known
-- thunk specs before raising this error?
didMatchThunkSpec :: ReadThunkError -> Bool
didMatchThunkSpec (ReadThunkError_UnrecognizedPaths x _) = isJust x
didMatchThunkSpec ReadThunkError_AmbiguousPackedState{} = True
didMatchThunkSpec _ = False

unpackedDirName :: FilePath
unpackedDirName = "."

attrCacheFileName :: FilePath
attrCacheFileName = ".attr-cache"

-- | A path from which our known-good nixpkgs can be fetched.
-- __NOTE__: This path is hardcoded, and only exists so subsumed thunk
-- specs (v7 specifically) can be parsed.
pinnedNixpkgsPath :: FilePath
pinnedNixpkgsPath = "/nix/store/qjg458n31xk1l6lj26c3b871d4i4is98-source"

-- | Specification for how a file in a thunk version works.
data ThunkFileSpec
  = ThunkFileSpec_Ptr (LBS.ByteString -> Either String ThunkPtr) -- ^ This file specifies 'ThunkPtr' data
  | ThunkFileSpec_FileMatches Text -- ^ This file must match the given content exactly
  | ThunkFileSpec_CheckoutIndicator -- ^ Existence of this directory indicates that the thunk is unpacked
  | ThunkFileSpec_AttrCache -- ^ This directory is an attribute cache

-- | Specification for how a set of files in a thunk version work.
data ThunkSpec = ThunkSpec
  { _thunkSpec_name :: !Text
  , _thunkSpec_files :: !(Map FilePath ThunkFileSpec)
  }

thunkSpecTypes :: NonEmpty (NonEmpty ThunkSpec)
thunkSpecTypes = gitThunkSpecs :| [gitHubThunkSpecs]

-- | Attempts to match a 'ThunkSpec' to a given directory.
matchThunkSpecToDir
  :: (MonadError ReadThunkError m, MonadIO m, MonadCatch m)
  => ThunkSpec -- ^ 'ThunkSpec' to match against the given files/directory
  -> FilePath -- ^ Path to directory
  -> Set FilePath -- ^ Set of file paths relative to the given directory
  -> m ThunkData
matchThunkSpecToDir thunkSpec dir dirFiles = do
  isCheckout <- fmap or $ flip Map.traverseWithKey (_thunkSpec_files thunkSpec) $ \expectedPath -> \case
    ThunkFileSpec_CheckoutIndicator -> liftIO (doesDirectoryExist (dir </> expectedPath))
    _ -> pure False
  case isCheckout of
    True -> pure ThunkData_Checkout
    False -> do
      datas <- fmap toList $ flip Map.traverseMaybeWithKey (_thunkSpec_files thunkSpec) $ \expectedPath -> \case
        ThunkFileSpec_AttrCache -> Nothing <$ dirMayExist expectedPath
        ThunkFileSpec_CheckoutIndicator -> pure Nothing -- Handled above
        ThunkFileSpec_FileMatches expectedContents -> handle (\(e :: IOError) -> throwError $ ReadThunkError_FileError expectedPath e) $ do
          actualContents <- liftIO (T.readFile $ dir </> expectedPath)
          case T.strip expectedContents == T.strip actualContents of
            True -> pure Nothing
            False -> throwError $ ReadThunkError_FileDoesNotMatch (dir </> expectedPath) expectedContents
        ThunkFileSpec_Ptr parser -> handle (\(e :: IOError) -> throwError $ ReadThunkError_FileError expectedPath e) $ do
          let path = dir </> expectedPath
          liftIO (doesFileExist path) >>= \case
            False -> pure Nothing
            True -> do
              actualContents <- liftIO $ LBS.readFile path
              case parser actualContents of
                Right v -> pure $ Just (thunkSpec, v)
                Left e -> throwError $ ReadThunkError_UnparseablePtr (dir </> expectedPath) e
      let matched = thunkSpec <$ nonEmpty datas
      for_ (nonEmpty (toList $ dirFiles `Set.difference` expectedPaths)) $ \fs ->
        throwError $ ReadThunkError_UnrecognizedPaths matched $ (dir </>) <$> fs
      for_ (nonEmpty (toList $ requiredPaths `Set.difference` dirFiles)) $ \fs ->
        throwError $ ReadThunkError_MissingPaths $ (dir </>) <$> fs

      uncurry ThunkData_Packed <$> case nonEmpty datas of
        Nothing -> throwError ReadThunkError_UnrecognizedThunk
        Just xs -> fold1WithM xs $ \a@(speca, ptrA) (specb, ptrB) ->
          if ptrA == ptrB then pure a else throwError $ ReadThunkError_AmbiguousPackedState speca specb
  where
    rootPathsOnly = Set.fromList . mapMaybe takeRootDir . Map.keys
    takeRootDir = fmap NonEmpty.head . nonEmpty . splitPath

    expectedPaths = rootPathsOnly $ _thunkSpec_files thunkSpec

    requiredPaths = rootPathsOnly $ Map.filter isRequiredFileSpec $ _thunkSpec_files thunkSpec
    isRequiredFileSpec = \case
      ThunkFileSpec_FileMatches _ -> True
      _ -> False

    dirMayExist expectedPath = liftIO (doesFileExist (dir </> expectedPath)) >>= \case
      True -> throwError $ ReadThunkError_UnrecognizedPaths Nothing $ expectedPath :| []
      False -> pure ()

    fold1WithM (x :| xs) f = foldM f x xs

readThunkWith
  :: (MonadNixThunk m)
  => NonEmpty (NonEmpty ThunkSpec) -> FilePath -> m (Either ReadThunkError ThunkData)
readThunkWith specTypes dir = do
  dirFiles <- Set.fromList <$> liftIO (listDirectory dir)
  let specs = concatMap toList $ toList $ NonEmpty.transpose specTypes -- Interleave spec types so we try each one in a "fair" ordering
  flip fix specs $ \loop -> \case
    [] -> pure $ Left ReadThunkError_UnrecognizedThunk
    spec:rest -> runExceptT (matchThunkSpecToDir spec dir dirFiles) >>= \case
      Left e
        -- If we matched one or more thunk specs, we fail early to tell
        -- the user exactly what's wrong:
        | didMatchThunkSpec e -> pure $ Left e
        -- Otherwise, keep looping:
        | otherwise -> putLog Debug [i|Thunk specification ${_thunkSpec_name spec} did not match ${dir}: ${prettyReadThunkError e}|] *> loop rest
      x@(Right _) -> x <$ putLog Debug [i|Thunk specification ${_thunkSpec_name spec} matched ${dir}|]

-- | Read a packed or unpacked thunk based on predefined thunk specifications.
readThunk :: (MonadNixThunk m) => FilePath -> m (Either ReadThunkError ThunkData)
readThunk = readThunkWith thunkSpecTypes

parseThunkPtr :: (Aeson.Object -> Aeson.Parser ThunkSource) -> Aeson.Object -> Aeson.Parser ThunkPtr
parseThunkPtr parseSrc v = do
  rev <- v Aeson..: "rev"
  sha256 <- v Aeson..: "sha256"
  src <- parseSrc v
  pure $ ThunkPtr
    { _thunkPtr_rev = ThunkRev
      { _thunkRev_commit = refFromHexString rev
      , _thunkRev_nixSha256 = sha256
      }
    , _thunkPtr_source = src
    }

parseGitHubSource :: Aeson.Object -> Aeson.Parser GitHubSource
parseGitHubSource v = do
  owner <- v Aeson..: "owner"
  repo <- v Aeson..: "repo"
  branch <- v Aeson..:! "branch"
  private <- v Aeson..:? "private"
  pure $ GitHubSource
    { _gitHubSource_owner = owner
    , _gitHubSource_repo = repo
    , _gitHubSource_branch = branch
    , _gitHubSource_private = fromMaybe False private
    }

parseGitSource :: Aeson.Object -> Aeson.Parser GitSource
parseGitSource v = do
  Just url <- parseGitUri <$> v Aeson..: "url"
  branch <- v Aeson..:! "branch"
  fetchSubmodules <- v Aeson..:! "fetchSubmodules"
  private <- v Aeson..:? "private"
  pure $ GitSource
    { _gitSource_url = url
    , _gitSource_branch = branch
    , _gitSource_fetchSubmodules = fromMaybe False fetchSubmodules
    , _gitSource_private = fromMaybe False private
    }

overwriteThunk :: MonadNixThunk m => FilePath -> ThunkPtr -> m ()
overwriteThunk target thunk = do
  -- Ensure that this directory is a valid thunk (i.e. so we aren't losing any data)
  readThunk target >>= \case
    Left e -> failReadThunkErrorWhile "while overwriting" e
    Right _ -> pure ()

  --TODO: Is there a safer way to do this overwriting?
  liftIO $ removePathForcibly target
  createThunk target $ Right thunk

thunkPtrToSpec :: ThunkPtr -> ThunkSpec
thunkPtrToSpec thunk = case _thunkPtr_source thunk of
  ThunkSource_GitHub _ -> NonEmpty.head gitHubThunkSpecs
  ThunkSource_Git _ -> NonEmpty.head gitThunkSpecs

-- It's important that formatting be very consistent here, because
-- otherwise when people update thunks, their patches will be messy
encodeThunkPtrData :: ThunkPtr -> LBS.ByteString
encodeThunkPtrData (ThunkPtr rev src) = case src of
  ThunkSource_GitHub s -> encodePretty' githubCfg $ Aeson.object $ catMaybes
    [ Just $ "owner" .= _gitHubSource_owner s
    , Just $ "repo" .= _gitHubSource_repo s
    , ("branch" .=) <$> _gitHubSource_branch s
    , Just $ "rev" .= refToHexString (_thunkRev_commit rev)
    , Just $ "sha256" .= _thunkRev_nixSha256 rev
    , Just $ "private" .= _gitHubSource_private s
    ]
  ThunkSource_Git s -> encodePretty' plainGitCfg $ Aeson.object $ catMaybes
    [ Just $ "url" .= gitUriToText (_gitSource_url s)
    , Just $ "rev" .= refToHexString (_thunkRev_commit rev)
    , ("branch" .=) <$> _gitSource_branch s
    , Just $ "sha256" .= _thunkRev_nixSha256 rev
    , Just $ "fetchSubmodules" .= _gitSource_fetchSubmodules s
    , Just $ "private" .= _gitSource_private s
    ]
 where
  githubCfg = defConfig
    { confIndent = Spaces 2
    , confCompare = keyOrder
        [ "owner"
        , "repo"
        , "branch"
        , "private"
        , "rev"
        , "sha256"
        ] <> compare
    , confTrailingNewline = True
    }
  plainGitCfg = defConfig
    { confIndent = Spaces 2
    , confCompare = keyOrder
        [ "url"
        , "rev"
        , "sha256"
        , "private"
        , "fetchSubmodules"
        ] <> compare
    , confTrailingNewline = True
    }

createThunk' :: MonadNixThunk m => ThunkCreateConfig -> m ()
createThunk' config = do
  newThunkPtr <- thunkCreateSourcePtr
    (_thunkCreateConfig_uri config)
    (_thunkConfig_private $ _thunkCreateConfig_config config)
    (untagName <$> _thunkCreateConfig_branch config)
    (T.pack . show <$> _thunkCreateConfig_rev config)
  let trailingDirectoryName = reverse . takeWhile (/= '/') . dropWhile (=='/') . reverse
      dropDotGit :: FilePath -> FilePath
      dropDotGit origName = fromMaybe origName $ stripExtension "git" origName

      defaultDestinationForGitUri :: GitUri -> FilePath
      defaultDestinationForGitUri = dropDotGit . trailingDirectoryName . T.unpack . URI.render . unGitUri

  destination <- case _thunkCreateConfig_uri config of
    ThunkCreateSource_Absolute uri -> pure $ fromMaybe (defaultDestinationForGitUri uri) $ _thunkCreateConfig_destination config
    ThunkCreateSource_Relative _ ->
      fromMaybe (failWith "When using a relative path as the thunk source, the destination path must be specified.") $
        fmap pure (_thunkCreateConfig_destination config)
  createThunk destination $ Right newThunkPtr

createThunk :: MonadNixThunk m => FilePath -> Either ThunkSpec ThunkPtr -> m ()
createThunk target ptrInfo = do
  isdir <- liftIO $ doesDirectoryExist target
  when isdir $ do
    isempty <- null <$> liftIO (listDirectory target)
    unless isempty $ failWith $ "Refusing to create thunk in non-empty directory " <> T.pack target

  ifor_ (_thunkSpec_files spec) $ \path -> \case
    ThunkFileSpec_FileMatches content -> withReadyPath path $ \p -> liftIO $ T.writeFile p content
    ThunkFileSpec_Ptr _ -> case ptrInfo of
      Left _ -> pure () -- We can't write the ptr without it
      Right ptr -> withReadyPath path $ \p -> liftIO $ LBS.writeFile p (encodeThunkPtrData ptr)
    _ -> pure ()
  where
    spec = either id thunkPtrToSpec ptrInfo
    withReadyPath path f = do
      let fullPath = target </> path
      putLog Debug $ "Writing thunk file " <> T.pack fullPath
      liftIO $ createDirectoryIfMissing True $ takeDirectory fullPath
      f fullPath

updateThunkToLatest :: MonadNixThunk m => ThunkUpdateConfig -> FilePath -> m ()
updateThunkToLatest (ThunkUpdateConfig mBranch thunkConfig) target = do
  withSpinner' ("Updating thunk " <> T.pack target <> " to latest") (pure $ const $ "Thunk " <> T.pack target <> " updated to latest") $ do
    checkThunkDirectory target
    -- check to see if thunk should be updated to a specific branch or just update it's current branch
    case mBranch of
      Nothing -> do
        (overwrite, ptr) <- readThunk target >>= \case
          Left err -> failReadThunkErrorWhile "during an update" err
          Right c -> case c of
            ThunkData_Packed _ t -> return (target, t)
            ThunkData_Checkout -> failWith "cannot update an unpacked thunk"
        let src = _thunkPtr_source ptr
        rev <- getLatestRev src
        overwriteThunk overwrite $ modifyThunkPtrByConfig thunkConfig $ ThunkPtr
          { _thunkPtr_source = src
          , _thunkPtr_rev = rev
          }
      Just branch -> readThunk target >>= \case
        Left err -> failReadThunkErrorWhile "during an update" err
        Right c -> case c of
          ThunkData_Packed _ t -> setThunk thunkConfig target (thunkSourceToGitSource $ _thunkPtr_source t) branch
          ThunkData_Checkout -> failWith [i|Thunk located at ${target} is unpacked. Use 'ob thunk pack' on the desired directory and then try 'ob thunk update' again.|]

setThunk :: MonadNixThunk m => ThunkConfig -> FilePath -> GitSource -> String -> m ()
setThunk thunkConfig target gs branch = do
  newThunkPtr <- uriThunkPtr (_gitSource_url gs) (_thunkConfig_private thunkConfig) (Just $ T.pack branch) Nothing
  overwriteThunk target newThunkPtr
  updateThunkToLatest (ThunkUpdateConfig Nothing thunkConfig) target

-- | All recognized github standalone loaders, ordered from newest to oldest.
-- This tool will only ever produce the newest one when it writes a thunk.
gitHubThunkSpecs :: NonEmpty ThunkSpec
gitHubThunkSpecs =
  gitHubThunkSpecV8 :|
  [ gitHubThunkSpecV7
  , gitHubThunkSpecV6
  , gitHubThunkSpecV5
  , gitHubThunkSpecV4
  , gitHubThunkSpecV3
  , gitHubThunkSpecV2
  , gitHubThunkSpecV1
  ]

gitHubThunkSpecV1 :: ThunkSpec
gitHubThunkSpecV1 = legacyGitHubThunkSpec "github-v1"
  "import ((import <nixpkgs> {}).fetchFromGitHub (builtins.fromJSON (builtins.readFile ./github.json)))"

gitHubThunkSpecV2 :: ThunkSpec
gitHubThunkSpecV2 = legacyGitHubThunkSpec "github-v2" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE" --TODO: Add something about how to get more info on NixThunk, etc.
  , "import ((import <nixpkgs> {}).fetchFromGitHub ("
  , "  let json = builtins.fromJSON (builtins.readFile ./github.json);"
  , "  in { inherit (json) owner repo rev sha256;"
  , "       private = json.private or false;"
  , "     }"
  , "))"
  ]

gitHubThunkSpecV3 :: ThunkSpec
gitHubThunkSpecV3 = legacyGitHubThunkSpec "github-v3" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let"
  , "  fetch = { private ? false, ... }@args: if private && builtins.hasAttr \"fetchGit\" builtins"
  , "    then fetchFromGitHubPrivate args"
  , "    else (import <nixpkgs> {}).fetchFromGitHub (builtins.removeAttrs args [\"branch\"]);"
  , "  fetchFromGitHubPrivate ="
  , "    { owner, repo, rev, branch ? null, name ? null, sha256 ? null, private ? false"
  , "    , fetchSubmodules ? false, githubBase ? \"github.com\", ..."
  , "    }: assert !fetchSubmodules;"
  , "      builtins.fetchGit ({"
  , "        url = \"ssh://git@${githubBase}/${owner}/${repo}.git\";"
  , "        inherit rev;"
  , "      }"
  , "      // (if branch == null then {} else { ref = branch; })"
  , "      // (if name == null then {} else { inherit name; }));"
  , "in import (fetch (builtins.fromJSON (builtins.readFile ./github.json)))"
  ]

gitHubThunkSpecV4 :: ThunkSpec
gitHubThunkSpecV4 = legacyGitHubThunkSpec "github-v4" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:"
  , "  if !fetchSubmodules && !private then builtins.fetchTarball {"
  , "    url = \"https://github.com/${owner}/${repo}/archive/${rev}.tar.gz\"; inherit sha256;"
  , "  } else (import <nixpkgs> {}).fetchFromGitHub {"
  , "    inherit owner repo rev sha256 fetchSubmodules private;"
  , "  };"
  , "in import (fetch (builtins.fromJSON (builtins.readFile ./github.json)))"
  ]

legacyGitHubThunkSpec :: Text -> Text -> ThunkSpec
legacyGitHubThunkSpec name loader = ThunkSpec name $ Map.fromList
  [ ("default.nix", ThunkFileSpec_FileMatches $ T.strip loader)
  , ("github.json" , ThunkFileSpec_Ptr parseGitHubJsonBytes)
  , (attrCacheFileName, ThunkFileSpec_AttrCache)
  , (".git", ThunkFileSpec_CheckoutIndicator)
  ]

gitHubThunkSpecV5 :: ThunkSpec
gitHubThunkSpecV5 = mkThunkSpec "github-v5" "github.json" parseGitHubJsonBytes [here|
# DO NOT HAND-EDIT THIS FILE
let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
  if !fetchSubmodules && !private then builtins.fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
  } else (import <nixpkgs> {}).fetchFromGitHub {
    inherit owner repo rev sha256 fetchSubmodules private;
  };
  json = builtins.fromJSON (builtins.readFile ./github.json);
in fetch json
|]

-- | See 'gitHubThunkSpecV7'.
--
-- __NOTE__: v6 spec thunks are broken! They import the pinned nixpkgs
-- in an incorrect way. GitHub thunks for public repositories with no
-- submodules will still work, but update as soon as possible.
gitHubThunkSpecV6 :: ThunkSpec
gitHubThunkSpecV6 = mkThunkSpec "github-v6" "github.json" parseGitHubJsonBytes [here|
# DO NOT HAND-EDIT THIS FILE
let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
  if !fetchSubmodules && !private then builtins.fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
  } else (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
  sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
}).fetchFromGitHub {
    inherit owner repo rev sha256 fetchSubmodules private;
  };
  json = builtins.fromJSON (builtins.readFile ./github.json);
in fetch json
|]

-- | Specification for GitHub thunks which use a specific, pinned
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@. The "v7" specs ensure that thunks can be fetched even
-- when @NIX_PATH@ is unset.
gitHubThunkSpecV7 :: ThunkSpec
gitHubThunkSpecV7 = mkThunkSpec "github-v7" "github.json" parseGitHubJsonBytes [i|# DO NOT HAND-EDIT THIS FILE
let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
  if !fetchSubmodules && !private then builtins.fetchTarball {
    url = "https://github.com/\${owner}/\${repo}/archive/\${rev}.tar.gz"; inherit sha256;
  } else (import ${pinnedNixpkgsPath} {}).fetchFromGitHub {
    inherit owner repo rev sha256 fetchSubmodules private;
  };
  json = builtins.fromJSON (builtins.readFile ./github.json);
in fetch json|]

-- | Specification for GitHub thunks which use a specific, pinned
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@.
--
-- Unlike 'gitHubThunKSpecV7', this thunk specification fetches the
-- nixpkgs tarball from GitHub, so it will fail on environments without
-- a network connection.
gitHubThunkSpecV8 :: ThunkSpec
gitHubThunkSpecV8 = mkThunkSpec "github-v8" "github.json" parseGitHubJsonBytes [here|
# DO NOT HAND-EDIT THIS FILE
let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
  if !fetchSubmodules && !private then builtins.fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
  } else (import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
  sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
}) {}).fetchFromGitHub {
    inherit owner repo rev sha256 fetchSubmodules private;
  };
  json = builtins.fromJSON (builtins.readFile ./github.json);
in fetch json
|]

parseGitHubJsonBytes :: LBS.ByteString -> Either String ThunkPtr
parseGitHubJsonBytes = parseJsonObject $ parseThunkPtr $ \v ->
  ThunkSource_GitHub <$> parseGitHubSource v <|> ThunkSource_Git <$> parseGitSource v

gitThunkSpecs :: NonEmpty ThunkSpec
gitThunkSpecs =
  gitThunkSpecV8 :|
  [ gitThunkSpecV7
  , gitThunkSpecV6
  , gitThunkSpecV5
  , gitThunkSpecV4
  , gitThunkSpecV3
  , gitThunkSpecV2
  , gitThunkSpecV1
  ]

gitThunkSpecV1 :: ThunkSpec
gitThunkSpecV1 = legacyGitThunkSpec "git-v1" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let fetchGit = {url, rev, ref ? null, branch ? null, sha256 ? null, fetchSubmodules ? null}:"
  , "  assert !fetchSubmodules; (import <nixpkgs> {}).fetchgit { inherit url rev sha256; };"
  , "in import (fetchGit (builtins.fromJSON (builtins.readFile ./git.json)))"
  ]

gitThunkSpecV2 :: ThunkSpec
gitThunkSpecV2 = legacyGitThunkSpec "git-v2" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let fetchGit = {url, rev, ref ? null, branch ? null, sha256 ? null, fetchSubmodules ? null}:"
  , "  if builtins.hasAttr \"fetchGit\" builtins"
  , "    then builtins.fetchGit ({ inherit url rev; } // (if branch == null then {} else { ref = branch; }))"
  , "    else abort \"Plain Git repositories are only supported on nix 2.0 or higher.\";"
  , "in import (fetchGit (builtins.fromJSON (builtins.readFile ./git.json)))"
  ]

-- This loader has a bug because @builtins.fetchGit@ is not given a @ref@
-- and will fail to find commits without this because it does shallow clones.
gitThunkSpecV3 :: ThunkSpec
gitThunkSpecV3 = legacyGitThunkSpec "git-v3" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let fetch = {url, rev, ref ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:"
  , "  let realUrl = let firstChar = builtins.substring 0 1 url; in"
  , "    if firstChar == \"/\" then /. + url"
  , "    else if firstChar == \".\" then ./. + url"
  , "    else url;"
  , "  in if !fetchSubmodules && private then builtins.fetchGit {"
  , "    url = realUrl; inherit rev;"
  , "  } else (import <nixpkgs> {}).fetchgit {"
  , "    url = realUrl; inherit rev sha256;"
  , "  };"
  , "in import (fetch (builtins.fromJSON (builtins.readFile ./git.json)))"
  ]

gitThunkSpecV4 :: ThunkSpec
gitThunkSpecV4 = legacyGitThunkSpec "git-v4" $ T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE"
  , "let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:"
  , "  let realUrl = let firstChar = builtins.substring 0 1 url; in"
  , "    if firstChar == \"/\" then /. + url"
  , "    else if firstChar == \".\" then ./. + url"
  , "    else url;"
  , "  in if !fetchSubmodules && private then builtins.fetchGit {"
  , "    url = realUrl; inherit rev;"
  , "    ${if branch == null then null else \"ref\"} = branch;"
  , "  } else (import <nixpkgs> {}).fetchgit {"
  , "    url = realUrl; inherit rev sha256;"
  , "  };"
  , "in import (fetch (builtins.fromJSON (builtins.readFile ./git.json)))"
  ]

legacyGitThunkSpec :: Text -> Text -> ThunkSpec
legacyGitThunkSpec name loader = ThunkSpec name $ Map.fromList
  [ ("default.nix", ThunkFileSpec_FileMatches $ T.strip loader)
  , ("git.json" , ThunkFileSpec_Ptr parseGitJsonBytes)
  , (attrCacheFileName, ThunkFileSpec_AttrCache)
  , (".git", ThunkFileSpec_CheckoutIndicator)
  ]

gitThunkSpecV5 :: ThunkSpec
gitThunkSpecV5 = mkThunkSpec "git-v5" "git.json" parseGitJsonBytes [here|
# DO NOT HAND-EDIT THIS FILE
let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
  let realUrl = let firstChar = builtins.substring 0 1 url; in
    if firstChar == "/" then /. + url
    else if firstChar == "." then ./. + url
    else url;
  in if !fetchSubmodules && private then builtins.fetchGit {
    url = realUrl; inherit rev;
    ${if branch == null then null else "ref"} = branch;
  } else (import <nixpkgs> {}).fetchgit {
    url = realUrl; inherit rev sha256;
  };
  json = builtins.fromJSON (builtins.readFile ./git.json);
in fetch json
|]

-- | See 'gitThunkSpecV7'.
-- __NOTE__: v6 spec thunks are broken! They import the pinned nixpkgs
-- in an incorrect way. GitHub thunks for public repositories with no
-- submodules will still work, but update as soon as possible.
gitThunkSpecV6 :: ThunkSpec
gitThunkSpecV6 = mkThunkSpec "git-v6" "git.json" parseGitJsonBytes [here|
# DO NOT HAND-EDIT THIS FILE
let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
  let realUrl = let firstChar = builtins.substring 0 1 url; in
    if firstChar == "/" then /. + url
    else if firstChar == "." then ./. + url
    else url;
  in if !fetchSubmodules && private then builtins.fetchGit {
    url = realUrl; inherit rev;
    ${if branch == null then null else "ref"} = branch;
  } else (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
  sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
}).fetchgit {
    url = realUrl; inherit rev sha256;
  };
  json = builtins.fromJSON (builtins.readFile ./git.json);
in fetch json
|]

-- | Specification for Git thunks which use a specific, pinned version
-- of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@. The "v7" specs ensure that thunks can be fetched even
-- when @NIX_PATH@ is unset.
gitThunkSpecV7 :: ThunkSpec
gitThunkSpecV7 = mkThunkSpec "git-v7" "git.json" parseGitJsonBytes [i|# DO NOT HAND-EDIT THIS FILE
let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
  let realUrl = let firstChar = builtins.substring 0 1 url; in
    if firstChar == "/" then /. + url
    else if firstChar == "." then ./. + url
    else url;
  in if !fetchSubmodules && private then builtins.fetchGit {
    url = realUrl; inherit rev;
    \${if branch == null then null else "ref"} = branch;
  } else (import ${pinnedNixpkgsPath} {}).fetchgit {
    url = realUrl; inherit rev sha256;
  };
  json = builtins.fromJSON (builtins.readFile ./git.json);
in fetch json|]

-- | Specification for Git thunks which use a specific, pinned version
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@.
--
-- Unlike 'gitHubThunKSpecV7', this thunk specification fetches the
-- nixpkgs tarball from GitHub, so it will fail on environments without
-- a network connection.
gitThunkSpecV8 :: ThunkSpec
gitThunkSpecV8 = mkThunkSpec "git-v7" "git.json" parseGitJsonBytes [i|# DO NOT HAND-EDIT THIS FILE
let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
  let realUrl = let firstChar = builtins.substring 0 1 url; in
    if firstChar == "/" then /. + url
    else if firstChar == "." then ./. + url
    else url;
  in if !fetchSubmodules && private then builtins.fetchGit {
    url = realUrl; inherit rev;
    \${if branch == null then null else "ref"} = branch;
  } else (import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
  sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
}) {}).fetchgit {
    url = realUrl; inherit rev sha256;
  };
  json = builtins.fromJSON (builtins.readFile ./git.json);
in fetch json|]

parseGitJsonBytes :: LBS.ByteString -> Either String ThunkPtr
parseGitJsonBytes = parseJsonObject $ parseThunkPtr $ fmap ThunkSource_Git . parseGitSource

mkThunkSpec :: Text -> FilePath -> (LBS.ByteString -> Either String ThunkPtr) -> Text -> ThunkSpec
mkThunkSpec name jsonFileName parser srcNix = ThunkSpec name $ Map.fromList
  [ ("default.nix", ThunkFileSpec_FileMatches defaultNixViaSrc)
  , ("thunk.nix", ThunkFileSpec_FileMatches srcNix)
  , (jsonFileName, ThunkFileSpec_Ptr parser)
  , (attrCacheFileName, ThunkFileSpec_AttrCache)
  , (normalise $ unpackedDirName </> ".git", ThunkFileSpec_CheckoutIndicator)
  ]
  where
    defaultNixViaSrc = [here|
# DO NOT HAND-EDIT THIS FILE
import (import ./thunk.nix)
|]


parseJsonObject :: (Aeson.Object -> Aeson.Parser a) -> LBS.ByteString -> Either String a
parseJsonObject p bytes = Aeson.parseEither p =<< Aeson.eitherDecode bytes

-- | Checks a cache directory to see if there is a fresh symlink
-- to the result of building an attribute of a thunk.
-- If no cache hit is found, nix-build is called to build the attribute
-- and the result is symlinked into the cache.
nixBuildThunkAttrWithCache
  :: ( MonadIO m
     , MonadLog Output m
     , HasCliConfig NixThunkError m
     , MonadMask m
     , MonadError NixThunkError m
     , MonadFail m
     )
  => ThunkSpec
  -> FilePath
  -- ^ Path to directory containing Thunk
  -> String
  -- ^ Attribute to build
  -> m (Maybe FilePath)
  -- ^ Symlink to cached or built nix output
-- WARNING: If the thunk uses an impure reference such as '<nixpkgs>'
-- the caching mechanism will fail as it merely measures the modification
-- time of the cache link and the expression to build.
nixBuildThunkAttrWithCache thunkSpec thunkDir attr = do
  latestChange <- liftIO $ do
    let
      getModificationTimeMaybe = fmap rightToMaybe . try @IOError . getModificationTime
      thunkFileNames = Map.keys $ _thunkSpec_files thunkSpec
    maximum . catMaybes <$> traverse (getModificationTimeMaybe . (thunkDir </>)) thunkFileNames

  let cachePaths' = nonEmpty $ Map.keys $ Map.filter (\case ThunkFileSpec_AttrCache -> True; _ -> False) $
                      _thunkSpec_files thunkSpec
  for cachePaths' $ \cachePaths ->
    fmap NonEmpty.head $ for cachePaths $ \cacheDir -> do
      let
        cachePath = thunkDir </> cacheDir </> attr <.> "out"
        cacheErrHandler e
          | isDoesNotExistError e = pure Nothing -- expected from a cache miss
          | otherwise = Nothing <$ putLog Error (T.pack $ displayException e)
      cacheHit <- handle cacheErrHandler $ do
        cacheTime <- liftIO $ posixSecondsToUTCTime . realToFrac . modificationTime <$> getSymbolicLinkStatus cachePath
        pure $ if latestChange <= cacheTime
          then Just cachePath
          else Nothing
      case cacheHit of
        Just c -> pure c
        Nothing -> do
          putLog Warning $ T.pack $ mconcat [thunkDir, ": ", attr, " not cached, building ..."]
          liftIO $ createDirectoryIfMissing True (takeDirectory cachePath)
          (cachePath <$) $ nixCmd $ NixCmd_Build $ def
            & nixBuildConfig_outLink .~ OutLink_IndirectRoot cachePath
            & nixCmdConfig_target .~ Target
              { _target_path = Just thunkDir
              , _target_attr = Just attr
              , _target_expr = Nothing
              }

-- | Build a nix attribute, and cache the result if possible
nixBuildAttrWithCache
  :: ( MonadLog Output m
     , HasCliConfig NixThunkError m
     , MonadIO m
     , MonadMask m
     , MonadError NixThunkError m
     , MonadFail m
     )
  => FilePath
  -- ^ Path to directory containing Thunk
  -> String
  -- ^ Attribute to build
  -> m FilePath
  -- ^ Symlink to cached or built nix output
nixBuildAttrWithCache exprPath attr = readThunk exprPath >>= \case
  -- Only packed thunks are cached. In particular, checkouts are not.
  Right (ThunkData_Packed spec _) ->
    maybe build pure =<< nixBuildThunkAttrWithCache spec exprPath attr
  _ -> build
  where
    build = nixCmd $ NixCmd_Build $ def
      & nixBuildConfig_outLink .~ OutLink_None
      & nixCmdConfig_target .~ Target
        { _target_path = Just exprPath
        , _target_attr = Just attr
        , _target_expr = Nothing
        }

-- | Safely update thunk using a custom action
--
-- A temporary working space is used to do any update. When the custom
-- action successfully completes, the resulting (packed) thunk is copied
-- back to the original location.
updateThunk :: MonadNixThunk m => FilePath -> (FilePath -> m a) -> m a
updateThunk p f = withSystemTempDirectory "obelisk-thunkptr-" $ \tmpDir -> do
  p' <- copyThunkToTmp tmpDir p
  unpackThunk' True p'
  result <- f p'
  updateThunkFromTmp p'
  return result
  where
    copyThunkToTmp tmpDir thunkDir = readThunk thunkDir >>= \case
      Left err -> failReadThunkErrorWhile "during an update" err
      Right ThunkData_Packed{} -> do
        let tmpThunk = tmpDir </> "thunk"
        callProcessAndLogOutput (Notice, Error) $
          proc cp ["-r", "-T", thunkDir, tmpThunk]
        return tmpThunk
      Right _ -> failWith "Thunk is not packed"
    updateThunkFromTmp p' = do
      _ <- packThunk' True (ThunkPackConfig False (ThunkConfig Nothing)) p'
      callProcessAndLogOutput (Notice, Error) $
        proc cp ["-r", "-T", p', p]

finalMsg :: Bool -> (a -> Text) -> Maybe (a -> Text)
finalMsg noTrail s = if noTrail then Nothing else Just s

-- | Check that we are not somewhere inside the thunk directory
checkThunkDirectory :: MonadNixThunk m => FilePath -> m ()
checkThunkDirectory thunkDir = do
  currentDir <- liftIO getCurrentDirectory
  thunkDir' <- liftIO $ canonicalizePath thunkDir
  when (thunkDir' `L.isInfixOf` currentDir) $
    failWith [i|Can't perform thunk operations from within the thunk directory: ${thunkDir}|]

  -- Don't let thunk commands work when directly given an unpacked repo
  when (takeFileName thunkDir == unpackedDirName) $
    readThunk (takeDirectory thunkDir) >>= \case
      Right _ -> failWith [i|Refusing to perform thunk operation on ${thunkDir} because it is a thunk's unpacked source|]
      Left _ -> pure ()

unpackThunk :: MonadNixThunk m => FilePath -> m ()
unpackThunk = unpackThunk' False

unpackThunk' :: MonadNixThunk m => Bool -> FilePath -> m ()
unpackThunk' noTrail thunkDir = checkThunkDirectory thunkDir *> readThunk thunkDir >>= \case
  Left err -> failReadThunkErrorWhile "while unpacking" err
  --TODO: Overwrite option that rechecks out thunk; force option to do so even if working directory is dirty
  Right ThunkData_Checkout -> failWith [i|Thunk at ${thunkDir} is already unpacked|]
  Right (ThunkData_Packed _ tptr) -> do
    let (thunkParent, thunkName) = splitFileName thunkDir
    withTempDirectory thunkParent thunkName $ \tmpThunk -> do
      let
        gitSrc = thunkSourceToGitSource $ _thunkPtr_source tptr
        newSpec = case _thunkPtr_source tptr of
          ThunkSource_GitHub _ -> NonEmpty.head gitHubThunkSpecs
          ThunkSource_Git _ -> NonEmpty.head gitThunkSpecs
      withSpinner' ("Fetching thunk " <> T.pack thunkName)
                   (finalMsg noTrail $ const $ "Fetched thunk " <> T.pack thunkName) $ do
        let unpackedPath = tmpThunk </> unpackedDirName
        gitCloneForThunkUnpack gitSrc (_thunkRev_commit $ _thunkPtr_rev tptr) unpackedPath

        let normalizeMore = dropTrailingPathSeparator . normalise
        when (normalizeMore unpackedPath /= normalizeMore tmpThunk) $ -- Only write meta data if the checkout is not inplace
          createThunk tmpThunk $ Left newSpec

        liftIO $ do
          removePathForcibly thunkDir
          renameDirectory tmpThunk thunkDir

gitCloneForThunkUnpack
  :: MonadNixThunk m
  => GitSource -- ^ Git source to use
  -> Ref hash -- ^ Commit hash to reset to
  -> FilePath -- ^ Directory to clone into
  -> m ()
gitCloneForThunkUnpack gitSrc commit dir = do
  _ <- readGitProcess dir $ [ "clone" ]
    ++  ["--recursive" | _gitSource_fetchSubmodules gitSrc]
    ++  [ T.unpack $ gitUriToText $ _gitSource_url gitSrc ]
    ++  do branch <- maybeToList $ _gitSource_branch gitSrc
           [ "--branch", T.unpack $ untagName branch ]
  _ <- readGitProcess dir ["reset", "--hard", refToHexString commit]
  when (_gitSource_fetchSubmodules gitSrc) $
    void $ readGitProcess dir ["submodule", "update", "--recursive", "--init"]

-- | Read a git process ignoring the global configuration (according to 'ignoreGitConfig').
readGitProcess :: MonadNixThunk m => FilePath -> [String] -> m Text
readGitProcess dir = readProcessAndLogOutput (Notice, Notice) . ignoreGitConfig . gitProc dir

-- | Prevent the called process from reading Git configuration. This
-- isn't as locked-down as 'isolateGitProc' to make sure the Git process
-- can still interact with the user (e.g. @ssh-askpass@), but it still
-- ignores enough of the configuration to ensure that thunks are
-- reproducible.
ignoreGitConfig :: ProcessSpec -> ProcessSpec
ignoreGitConfig = setEnvOverride (envfix <>)
  where
    -- Ignore both global (user's) and system (... system-wide) git
    -- configuration.
    envfix = Map.fromList
      [ ("GIT_CONFIG_NOSYSTEM", "yes")
      -- Git documentation says GIT_CONFIG_GLOBAL=/dev/null should
      -- prevent it from reading the global config file but that's a
      -- lie, actually.
      , ("HOME", "/dev/null")
      , ("XDG_CONFIG_HOME", "/dev/null")
      ]

--TODO: add a rollback mode to pack to the original thunk
packThunk :: MonadNixThunk m => ThunkPackConfig -> FilePath -> m ThunkPtr
packThunk = packThunk' False

packThunk' :: MonadNixThunk m => Bool -> ThunkPackConfig -> FilePath -> m ThunkPtr
packThunk' noTrail (ThunkPackConfig force thunkConfig) thunkDir = checkThunkDirectory thunkDir *> readThunk thunkDir >>= \case
  Right ThunkData_Packed{} -> failWith [i|Thunk at ${thunkDir} is is already packed|]
  _ -> withSpinner'
    ("Packing thunk " <> T.pack thunkDir)
    (finalMsg noTrail $ const $ "Packed thunk " <> T.pack thunkDir) $
    do
      let checkClean = if force then CheckClean_NoCheck else CheckClean_FullCheck
      thunkPtr <- modifyThunkPtrByConfig thunkConfig <$> getThunkPtr checkClean thunkDir (_thunkConfig_private thunkConfig)
      liftIO $ removePathForcibly thunkDir
      createThunk thunkDir $ Right thunkPtr
      pure thunkPtr

modifyThunkPtrByConfig :: ThunkConfig -> ThunkPtr -> ThunkPtr
modifyThunkPtrByConfig (ThunkConfig markPrivate') ptr = case markPrivate' of
  Nothing -> ptr
  Just markPrivate -> ptr { _thunkPtr_source = case _thunkPtr_source ptr of
      ThunkSource_Git s -> ThunkSource_Git $ s { _gitSource_private = markPrivate }
      ThunkSource_GitHub s -> ThunkSource_GitHub $ s { _gitHubSource_private = markPrivate }
    }

data CheckClean
  = CheckClean_FullCheck
  -- ^ Check that the repo is clean, including .gitignored files
  | CheckClean_NotIgnored
  -- ^ Check that the repo is clean, not including .gitignored files
  | CheckClean_NoCheck
  -- ^ Don't check that the repo is clean

getThunkPtr :: forall m. MonadNixThunk m => CheckClean -> FilePath -> Maybe Bool -> m ThunkPtr
getThunkPtr gitCheckClean dir mPrivate = do
  let repoLocations = nubOrd $ map (first normalise)
        [(".git", "."), (unpackedDirName </> ".git", unpackedDirName)]
  repoLocation' <- liftIO $ flip findM repoLocations $ doesDirectoryExist . (dir </>) . fst
  thunkDir <- case repoLocation' of
    Nothing -> failWith [i|Can't find an unpacked thunk in ${dir}|]
    Just (_, path) -> pure $ normalise $ dir </> path

  let (checkClean, checkIgnored) = case gitCheckClean of
        CheckClean_FullCheck -> (True, True)
        CheckClean_NotIgnored -> (True, False)
        CheckClean_NoCheck -> (False, False)
  when checkClean $ ensureCleanGitRepo thunkDir checkIgnored
    "thunk pack: thunk checkout contains unsaved modifications"

  -- Check whether there are any stashes
  when checkClean $ do
    stashOutput <- readGitProcess thunkDir ["stash", "list"]
    unless (T.null stashOutput) $
      failWith $ T.unlines $
        [ "thunk pack: thunk checkout has stashes"
        , "git stash list:"
        ] ++ T.lines stashOutput

  -- Get current branch
  (mCurrentBranch, mCurrentCommit) <- do
    b <- listToMaybe . T.lines <$> readGitProcess thunkDir ["rev-parse", "--abbrev-ref", "HEAD"]
    c <- listToMaybe . T.lines <$> readGitProcess thunkDir ["rev-parse", "HEAD"]
    case b of
      (Just "HEAD") -> failWith $ T.unlines
        [ "thunk pack: You are in 'detached HEAD' state."
        , "If you want to pack at the current ref \
          \then please create a new branch with 'git checkout -b <new-branch-name>' and push this upstream."
        ]
      _ -> return (b, c)

  -- Get information on all branches and their (optional) designated upstream
  -- correspondents
  headDump :: [Text] <- T.lines <$> readGitProcess thunkDir
    [ "for-each-ref"
    , "--format=%(refname:short) %(upstream:short) %(upstream:remotename)"
    , "refs/heads/"
    ]

  (headInfo :: Map Text (Maybe (Text, Text)))
    <- fmap Map.fromList $ forM headDump $ \line -> do
      (branch : restOfLine) <- pure $ T.words line
      mUpstream <- case restOfLine of
        [] -> pure Nothing
        [u, r] -> pure $ Just (u, r)
        (_:_) -> failWith "git for-each-ref invalid output"
      pure (branch, mUpstream)

  putLog Debug $ "branches: " <> T.pack (show headInfo)

  let errorMap :: Map Text ()
      headUpstream :: Map Text (Text, Text)
      (errorMap, headUpstream) = flip Map.mapEither headInfo $ \case
        Nothing -> Left ()
        Just b -> Right b

  putLog Debug $ "branches with upstream branch set: " <> T.pack (show headUpstream)

  -- Check that every branch has a remote equivalent
  when checkClean $ do
    let untrackedBranches = Map.keys errorMap
    when (not $ L.null untrackedBranches) $ failWith $ T.unlines $
      [ "thunk pack: Certain branches in the thunk have no upstream branch \
        \set. This means we don't know to check whether all your work is \
        \saved. The offending branches are:"
      , ""
      , T.unwords untrackedBranches
      , ""
      , "To fix this, you probably want to do:"
      , ""
      ] ++
      ((\branch -> "git push -u origin " <> branch) <$> untrackedBranches) ++
      [ ""
      , "These will push the branches to the default remote under the same \
        \name, and (thanks to the `-u`) remember that choice so you don't \
        \get this error again."
      ]

    -- loosely by https://stackoverflow.com/questions/7773939/show-git-ahead-and-behind-info-for-all-branches-including-remotes
    stats <- ifor headUpstream $ \branch (upstream, _remote) -> do
      (stat :: [Text]) <- T.lines <$> readGitProcess thunkDir
        [ "rev-list", "--left-right"
        , T.unpack branch <> "..." <> T.unpack upstream
        ]
      let ahead = length $ [ () | Just ('<', _) <- T.uncons <$> stat ]
          behind = length $ [ () | Just ('>', _) <- T.uncons <$> stat ]
      pure (upstream, (ahead, behind))

    -- Those branches which have commits ahead of, i.e. not on, the upstream
    -- branch. Purely being behind is fine.
    let nonGood = Map.filter ((/= 0) . fst . snd) stats

    when (not $ Map.null nonGood) $ failWith $ T.unlines $
      [ "thunk pack: Certain branches in the thunk have commits not yet pushed upstream:"
      , ""
      ] ++
      flip map (Map.toList nonGood) (\(branch, (upstream, (ahead, behind))) -> mconcat
        ["  ", branch, " ahead: ", T.pack (show ahead), " behind: ", T.pack (show behind), " remote branch ", upstream]) ++
      [ ""
      , "Please push these upstream and try again. (Or just fetch, if they are somehow \
        \pushed but this repo's remote tracking branches don't know it.)"
      ]

  when checkClean $ do
    -- We assume it's safe to pack the thunk at this point
    putLog Informational "All changes safe in git remotes. OK to pack thunk."

  let remote = maybe "origin" snd $ flip Map.lookup headUpstream =<< mCurrentBranch

  [remoteUri'] <- fmap T.lines $ readGitProcess thunkDir
    [ "config"
    , "--get"
    , "remote." <> T.unpack remote <> ".url"
    ]

  remoteUri <- case parseGitUri remoteUri' of
    Nothing -> failWith $ "Could not identify git remote: " <> remoteUri'
    Just uri -> pure uri
  uriThunkPtr remoteUri mPrivate mCurrentBranch mCurrentCommit

-- | Get the latest revision available from the given source
getLatestRev :: MonadNixThunk m => ThunkSource -> m ThunkRev
getLatestRev os = do
  let gitS = thunkSourceToGitSource os
  (_, commit) <- gitGetCommitBranch (_gitSource_url gitS) (untagName <$> _gitSource_branch gitS)
  case os of
    ThunkSource_GitHub s -> githubThunkRev s commit
    ThunkSource_Git s -> gitThunkRev s commit

-- | Convert a URI to a thunk
--
-- If the URL is a github URL, we try to just download an archive for
-- performance. If that doesn't work (e.g. authentication issue), we fall back
-- on just doing things the normal way for git repos in general, and save it as
-- a regular git thunk.
uriThunkPtr :: MonadNixThunk m => GitUri -> Maybe Bool -> Maybe Text -> Maybe Text -> m ThunkPtr
uriThunkPtr uri mPrivate mbranch mcommit = do
  commit <- case mcommit of
    Nothing -> gitGetCommitBranch uri mbranch >>= return . snd
    (Just c) -> return c
  (src, rev) <- uriToThunkSource uri mPrivate mbranch >>= \case
    ThunkSource_GitHub s -> do
      rev <- runExceptT $ githubThunkRev s commit
      case rev of
        Right r -> pure (ThunkSource_GitHub s, r)
        Left e -> do
          putLog Warning "\
\Failed to fetch archive from GitHub. This is probably a private repo. \
\Falling back on normal fetchgit. Original failure:"
          putLog Warning $ prettyNixThunkError e
          let s' = forgetGithub True s
          (,) (ThunkSource_Git s') <$> gitThunkRev s' commit
    ThunkSource_Git s -> (,) (ThunkSource_Git s) <$> gitThunkRev s commit
  pure $ ThunkPtr
    { _thunkPtr_rev = rev
    , _thunkPtr_source = src
    }

-- | Convert a 'ThunkCreateSource` to a 'ThunkPtr'.
thunkCreateSourcePtr
  :: MonadNixThunk m
  => ThunkCreateSource  -- ^ Where is the repository?
  -> Maybe Bool         -- ^ Is it private?
  -> Maybe Text         -- ^ Shall we fetch a specific branch?
  -> Maybe Text         -- ^ Shall we check out a specific commit?
  -> m ThunkPtr
thunkCreateSourcePtr source mPriv mBranch mCommit = do
  uri <- case source of
    ThunkCreateSource_Absolute uri -> pure uri
    ThunkCreateSource_Relative dir -> do
      isdir <- liftIO $ doesDirectoryExist dir
      if isdir
        then do
          absolute <- liftIO $ makeAbsolute dir
          pure $ fromMaybe (error "parsing a file:// URI should never fail") $
            parseGitUri ("file://" <> T.pack absolute)
        else failWith $ "Path does not refer to a directory: " <> T.pack dir
  uriThunkPtr uri mPriv mBranch mCommit

-- | N.B. Cannot infer all fields.
--
-- If the thunk is a GitHub thunk and fails, we do *not* fall back like with
-- `uriThunkPtr`. Unlike a plain URL, a thunk src explicitly states which method
-- should be employed, and so we respect that.
uriToThunkSource :: MonadNixThunk m => GitUri -> Maybe Bool -> Maybe Text -> m ThunkSource
uriToThunkSource (GitUri u) mPrivate
  | Right uriAuth <- URI.uriAuthority u
  , Just scheme <- URI.unRText <$> URI.uriScheme u
  , case scheme of
      "ssh" -> uriAuth == URI.Authority
        { URI.authUserInfo = Just $ URI.UserInfo (fromRight' $ URI.mkUsername "git") Nothing
        , URI.authHost = fromRight' $ URI.mkHost "github.com"
        , URI.authPort = Nothing
        }
      s -> s `L.elem` [ "git", "https", "http" ] -- "http:" just redirects to "https:"
        && URI.unRText (URI.authHost uriAuth) == "github.com"
  , Just (_, owner :| [repoish]) <- URI.uriPath u
  = \mbranch -> do
      isPrivate <- getIsPrivate
      pure $ ThunkSource_GitHub $ GitHubSource
        { _gitHubSource_owner = N $ URI.unRText owner
        , _gitHubSource_repo = N $ let
            repoish' = URI.unRText repoish
          in fromMaybe repoish' $ T.stripSuffix ".git" repoish'
        , _gitHubSource_branch = N <$> mbranch
        , _gitHubSource_private = isPrivate
        }

  | otherwise = \mbranch -> do
      isPrivate <- getIsPrivate
      pure $ ThunkSource_Git $ GitSource
        { _gitSource_url = GitUri u
        , _gitSource_branch = N <$> mbranch
        , _gitSource_fetchSubmodules = False -- TODO: How do we determine if this should be true?
        , _gitSource_private = isPrivate
        }
  where
    getIsPrivate = maybe (guessGitRepoIsPrivate $ GitUri u) pure mPrivate

guessGitRepoIsPrivate :: MonadNixThunk m => GitUri -> m Bool
guessGitRepoIsPrivate uri = flip fix urisToTry $ \loop -> \case
  [] -> pure True
  uriAttempt:xs -> do
    result <- readCreateProcessWithExitCode $
      isolateGitProc $
        gitProcNoRepo
          [ "ls-remote"
          , "--quiet"
          , "--exit-code"
          , "--symref"
          , T.unpack $ gitUriToText uriAttempt
          ]
    case result of
      (ExitSuccess, _, _) -> pure False -- Must be a public repo
      _ -> loop xs
  where
    urisToTry = nubOrd $
      -- Include the original URI if it isn't using SSH because SSH will certainly fail.
      [uri | fmap URI.unRText (URI.uriScheme (unGitUri uri)) /= Just "ssh"] <>
      [changeScheme "https" uri, changeScheme "http" uri]
    changeScheme scheme (GitUri u) = GitUri $ u
      { URI.uriScheme = URI.mkScheme scheme
      , URI.uriAuthority = (\x -> x { URI.authUserInfo = Nothing }) <$> URI.uriAuthority u
      }

-- Funny signature indicates no effects depend on the optional branch name.
githubThunkRev
  :: forall m
  .  MonadNixThunk m
  => GitHubSource
  -> Text
  -> m ThunkRev
githubThunkRev s commit = do
  owner <- forcePP $ _gitHubSource_owner s
  repo <- forcePP $ _gitHubSource_repo s
  revTarball <- URI.mkPathPiece $ commit <> ".tar.gz"
  let archiveUri = GitUri $ URI.URI
        { URI.uriScheme = Just $ fromRight' $ URI.mkScheme "https"
        , URI.uriAuthority = Right $ URI.Authority
          { URI.authUserInfo = Nothing
          , URI.authHost = fromRight' $ URI.mkHost "github.com"
          , URI.authPort = Nothing
          }
        , URI.uriPath = Just ( False
                         , owner :| [ repo, fromRight' $ URI.mkPathPiece "archive", revTarball ]
                     )
    , URI.uriQuery = []
    , URI.uriFragment = Nothing
    }
  hash <- getNixSha256ForUriUnpacked archiveUri
  putLog Debug $ "Nix sha256 is " <> hash
  return $ ThunkRev
    { _thunkRev_commit = commitNameToRef $ N commit
    , _thunkRev_nixSha256 = hash
    }
  where
    forcePP :: Name entity -> m (URI.RText 'URI.PathPiece)
    forcePP = URI.mkPathPiece . untagName

gitThunkRev
  :: MonadNixThunk m
  => GitSource
  -> Text
  -> m ThunkRev
gitThunkRev s commit = do
  let u = _gitSource_url s
      protocols = ["file", "https", "ssh", "git"]
      scheme = maybe "file" URI.unRText $ URI.uriScheme $ (\(GitUri x) -> x) u
  unless (T.toLower scheme `elem` protocols) $
    failWith $ "obelisk currently only supports "
      <> T.intercalate ", " protocols <> " protocols for plain Git remotes"
  hash <- nixPrefetchGit u commit $ _gitSource_fetchSubmodules s
  putLog Informational $ "Nix sha256 is " <> hash
  pure $ ThunkRev
    { _thunkRev_commit = commitNameToRef (N commit)
    , _thunkRev_nixSha256 = hash
    }

-- | Given the URI to a git remote, and an optional branch name, return the name
-- of the branch along with the hash of the commit at tip of that branch.
--
-- If the branch name is passed in, it is returned exactly as-is. If it is not
-- passed it, the default branch of the repo is used instead.

gitGetCommitBranch
  :: MonadNixThunk m => GitUri -> Maybe Text -> m (Text, CommitId)
gitGetCommitBranch uri mbranch = withExitFailMessage ("Failure for git remote " <> uriMsg) $ do
  (_, bothMaps) <- gitLsRemote
    (T.unpack $ gitUriToText uri)
    (GitRef_Branch <$> mbranch)
    Nothing
  branch <- case mbranch of
    Nothing -> withExitFailMessage "Failed to find default branch" $ do
      b <- rethrowE $ gitLookupDefaultBranch bothMaps
      putLog Debug $ "Default branch for remote repo " <> uriMsg <> " is " <> b
      pure b
    Just b -> pure b
  commit <- rethrowE $ gitLookupCommitForRef bothMaps (GitRef_Branch branch)
  putLog Informational $ "Latest commit in branch " <> branch
    <> " from remote repo " <> uriMsg
    <> " is " <> commit
  pure (branch, commit)
  where
    rethrowE = either failWith pure
    uriMsg = gitUriToText uri

parseGitUri :: Text -> Maybe GitUri
parseGitUri x = GitUri <$> (parseFileURI x <|> parseAbsoluteURI x <|> parseSshShorthand x)

parseFileURI :: Text -> Maybe URI.URI
parseFileURI uri = if "/" `T.isPrefixOf` uri then parseAbsoluteURI ("file://" <> uri) else Nothing

parseAbsoluteURI :: Text -> Maybe URI.URI
parseAbsoluteURI uri = do
  parsedUri <- URI.mkURI uri
  guard $ URI.isPathAbsolute parsedUri
  pure parsedUri

parseSshShorthand :: Text -> Maybe URI.URI
parseSshShorthand uri = do
  -- This is what git does to check that the remote
  -- is not a local file path when parsing shorthand.
  -- Last referenced from here:
  -- https://github.com/git/git/blob/95ec6b1b3393eb6e26da40c565520a8db9796e9f/connect.c#L712
  let
    (authAndHostname, colonAndPath) = T.break (== ':') uri
    properUri = "ssh://" <> authAndHostname <> "/" <> T.drop 1 colonAndPath
  -- Shorthand is valid iff a colon is present and it occurs before the first slash
  -- This check is used to disambiguate a filepath containing a colon from shorthand
  guard $ isNothing (T.findIndex (=='/') authAndHostname)
        && not (T.null colonAndPath)
  URI.mkURI properUri

-- The following code has been adapted from the 'Data.Git.Ref',
-- which is apparently no longer maintained

-- | Represent a git reference (SHA1)
newtype Ref hash = Ref { unRef :: Digest hash }
  deriving (Eq, Ord, Typeable)

-- | Invalid Reference exception raised when
-- using something that is not a ref as a ref.
newtype RefInvalid = RefInvalid { unRefInvalid :: ByteString }
  deriving (Show, Eq, Data, Typeable)

instance Exception RefInvalid

refFromHexString :: HashAlgorithm hash => String -> Ref hash
refFromHexString = refFromHex . BSC.pack

refFromHex :: HashAlgorithm hash => BSC.ByteString -> Ref hash
refFromHex s =
  case convertFromBase Base16 s :: Either String ByteString of
    Left _ -> throw $ RefInvalid s
    Right h -> case digestFromByteString h of
      Nothing -> throw $ RefInvalid s
      Just d -> Ref d

-- | transform a ref into an hexadecimal string
refToHexString :: Ref hash -> String
refToHexString (Ref d) = show d

instance Show (Ref hash) where
  show (Ref bs) = BSC.unpack $ convertToBase Base16 bs
