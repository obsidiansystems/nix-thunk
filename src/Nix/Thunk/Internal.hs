module Nix.Thunk.Internal where

import Bindings.Cli.Coreutils (cp)
import Bindings.Cli.Git
  ( CommitId
  , GitRef (GitRef_Branch)
  , ensureCleanGitRepo
  , gitLookupCommitForRef
  , gitLookupDefaultBranch
  , gitLsRemote
  , gitProc
  , gitProcNoRepo
  , isolateGitProc
  )
import Bindings.Cli.Nix
import Cli.Extras
import Cli.Extras qualified as Cli
import Control.Applicative
import Control.Exception (Exception, displayException, throw, try)
import Control.Lens (ifor, ifor_, makePrisms, (.~))
import Control.Monad
import Control.Monad.Catch (MonadCatch, MonadMask, handle, onException)
import Control.Monad.Except
import Control.Monad.Extra (findM)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Log (MonadLog)
import Crypto.Hash (Digest, HashAlgorithm, SHA1 (SHA1), digestFromByteString, hashWith)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty
import Data.Aeson.Types qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as LBS
import Data.Containers.ListUtils (nubOrd)
import Data.Data (Data)
import Data.Default
import Data.Either.Combinators (fromRight', rightToMaybe)
import Data.Foldable (find, fold, for_, toList)
import Data.Function
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String.Here.Interpolated (i)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding
import Data.Text.IO qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Traversable
import Data.Yaml (parseMaybe)
import GitHub
import GitHub.Data.Name
import System.Directory
import System.Exit
import System.FilePath
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp
import System.Posix.Files
import System.Which (staticWhich)
import Text.URI qualified as URI

import Nix.Thunk.Flake qualified as Flake

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

-- | Runs a 'MonadNixThunk' action without interactive terminal output.
runMonadNixThunk :: forall a. (forall m. MonadNixThunk m => m a) -> IO (Either NixThunkError a)
runMonadNixThunk x = do
  cliConf <- newCliConfig Error True True (\e -> (prettyNixThunkError e, ExitFailure 1))
  runCli cliConf $ catchError (Right <$> x) (pure . Left)

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

-- TODO: Support symlinked thunk data
data ThunkData
  = -- | Packed thunk
    ThunkData_Packed ThunkSpec ThunkPtr
  | -- | Checked out thunk that was unpacked from this pointer
    ThunkData_Checkout

-- | A reference to the exact data that a thunk should translate into
data ThunkPtr = ThunkPtr
  { _thunkPtr_rev :: ThunkRev
  , _thunkPtr_source :: ThunkSource
  }
  deriving stock (Eq, Ord, Show)

type NixSha256 = Text -- TODO: Use a smart constructor and make this actually verify itself

-- | A specific revision of data; it may be available from multiple sources
data ThunkRev = ThunkRev
  { _thunkRev_commit :: Ref SHA1
  , _thunkRev_nixSha256 :: NixSha256
  }
  deriving stock (Eq, Ord, Show)

-- | A location from which a thunk's data can be retrieved
data ThunkSource
  = -- | A source specialized for GitHub
    ThunkSource_GitHub GitHubSource
  | -- | A plain repo source
    ThunkSource_Git GitSource
  deriving stock (Eq, Ord, Show)

thunkSourceToGitSource :: ThunkSource -> GitSource
thunkSourceToGitSource = \case
  ThunkSource_GitHub s -> forgetGithub False s
  ThunkSource_Git s -> s

setThunkSourceBranch :: Maybe (Name Branch) -> ThunkSource -> ThunkSource
setThunkSourceBranch mb = \case
  ThunkSource_GitHub s -> ThunkSource_GitHub $ s {_gitHubSource_branch = mb}
  ThunkSource_Git s -> ThunkSource_Git $ s {_gitSource_branch = mb}

thunkSourceFetchSubmodules :: ThunkSource -> Bool
thunkSourceFetchSubmodules = \case
  ThunkSource_GitHub s -> _gitHubSource_fetchSubmodules s
  ThunkSource_Git s -> _gitSource_fetchSubmodules s

setThunkSourceSubmodules :: Bool -> ThunkSource -> ThunkSource
setThunkSourceSubmodules b = \case
  ThunkSource_GitHub s -> ThunkSource_GitHub $ s {_gitHubSource_fetchSubmodules = b}
  ThunkSource_Git s -> ThunkSource_Git $ s {_gitSource_fetchSubmodules = b}

data GitHubSource = GitHubSource
  { _gitHubSource_owner :: Name Owner
  , _gitHubSource_repo :: Name Repo
  , _gitHubSource_branch :: Maybe (Name Branch)
  , _gitHubSource_fetchSubmodules :: Bool
  , _gitHubSource_private :: Bool
  }
  deriving stock (Eq, Ord, Show)

newtype GitUri = GitUri {unGitUri :: URI.URI} deriving stock (Eq, Ord, Show)

gitUriToText :: GitUri -> Text
gitUriToText (GitUri uri)
  | (T.toLower . URI.unRText <$> URI.uriScheme uri) == Just "file"
  , Just (_, path) <- URI.uriPath uri =
      "/" <> T.intercalate "/" (map URI.unRText $ NonEmpty.toList path)
  | otherwise = URI.render uri

-- | A flake reference needs the URL in full. 'gitUriToText' drops the scheme
-- from a @file@ URI, because the generated loaders need a bare path.
flakeUriToText :: GitUri -> Text
flakeUriToText = URI.render . unGitUri

data GitSource = GitSource
  { _gitSource_url :: GitUri
  , _gitSource_branch :: Maybe (Name Branch)
  , _gitSource_fetchSubmodules :: Bool
  , _gitSource_private :: Bool
  }
  deriving stock (Eq, Ord, Show)

data ThunkConfig = ThunkConfig
  { _thunkConfig_private :: Maybe Bool
  , _thunkConfig_submodules :: Maybe Bool
  -- ^ Whether the repository needs its submodules. The github fetcher cannot
  -- fetch them, so a thunk that needs them is read through the git fetcher.
  , _thunkConfig_noFlake :: Bool
  -- ^ Write the newest thunk format that carries no flake files. A consumer
  -- cannot use such a thunk as a flake input. This format serves a project that
  -- does not want the flake interface, and a project that cannot produce one.
  }
  deriving stock (Show)

data ThunkUpdateConfig = ThunkUpdateConfig
  { _thunkUpdateConfig_branch :: Maybe Text
  , _thunkUpdateConfig_ref :: Maybe Text
  , _thunkUpdateConfig_thunk :: ThunkConfig
  }
  deriving stock (Show)

data ThunkPackConfig = ThunkPackConfig
  { _thunkPackConfig_force :: Bool
  , _thunkPackConfig_config :: ThunkConfig
  }
  deriving stock (Show)

-- | The source to be used for creating thunks.
data ThunkCreateSource
  = -- | Create a thunk from an absolute reference to a Git repository:
    -- URIs like @file://@, @https://@, @ssh://@ etc.
    ThunkCreateSource_Absolute GitUri
  | -- | Create a thunk from a local folder. If the folder exists, then
    -- it is made absolute using the current working directory and
    -- treated as a @file://@ URL.
    ThunkCreateSource_Relative FilePath
  deriving stock (Show)

data ThunkCreateConfig = ThunkCreateConfig
  { _thunkCreateConfig_uri :: ThunkCreateSource
  , _thunkCreateConfig_branch :: Maybe (Name Branch)
  , _thunkCreateConfig_rev :: Maybe (Ref SHA1)
  , _thunkCreateConfig_config :: ThunkConfig
  , _thunkCreateConfig_destination :: Maybe FilePath
  }
  deriving stock (Show)

data CreateWorktreeConfig = CreateWorktreeConfig
  { _createWorktreeConfig_branch :: Maybe String
  , _createWorktreeConfig_detach :: Bool
  }
  deriving stock (Show)

-- | Convert a GitHub source to a regular Git source.
forgetGithub :: Bool -> GitHubSource -> GitSource
forgetGithub useSsh s =
  GitSource
    { _gitSource_url = GitUri uri
    , _gitSource_branch = _gitHubSource_branch s
    , _gitSource_fetchSubmodules = _gitHubSource_fetchSubmodules s
    , _gitSource_private = _gitHubSource_private s
    }
  where
    uri =
      URI.URI
        { URI.uriScheme = Just $ fromRight' $ URI.mkScheme $ if useSsh then "ssh" else "https"
        , URI.uriAuthority = Right authority
        , URI.uriPath = Just (False, path)
        , URI.uriQuery = []
        , URI.uriFragment = Nothing
        }
    authority =
      URI.Authority
        { URI.authUserInfo = URI.UserInfo (fromRight' $ URI.mkUsername "git") Nothing <$ guard useSsh
        , URI.authHost = fromRight' $ URI.mkHost "github.com"
        , URI.authPort = Nothing
        }
    path =
      fromRight' . URI.mkPathPiece
        <$> untagName (_gitHubSource_owner s)
          :| [untagName (_gitHubSource_repo s) <> ".git"]

-- | 'maximum' is partial on empty containers; this yields 'Nothing' there.
maximumMaybe :: Ord a => [a] -> Maybe a
maximumMaybe = foldr (\x -> Just . maybe x (max x)) Nothing

commitNameToRef :: Name Commit -> Ref SHA1
commitNameToRef (N c) = refFromHex $ encodeUtf8 c

-- TODO: Use spinner here.
getNixSha256ForUriUnpacked
  :: MonadNixThunk m
  => GitUri
  -> m NixSha256
getNixSha256ForUriUnpacked uri =
  withExitFailMessage ("nix-prefetch-url: Failed to determine sha256 hash of URL " <> gitUriToText uri) $ do
    out <-
      fmap T.lines $
        readProcessAndLogOutput (Debug, Debug) $
          Cli.proc nixPrefetchUrlPath ["--unpack", "--type", "sha256", T.unpack $ gitUriToText uri]
    case out of
      [hash] -> pure hash
      _ -> failWith $ "nix-prefetch-url: unrecognized output " <> T.unlines out

nixPrefetchGit :: MonadNixThunk m => GitUri -> Text -> Bool -> m NixSha256
nixPrefetchGit uri rev fetchSubmodules =
  withExitFailMessage ("nix-prefetch-git: Failed to determine sha256 hash of Git repo " <> gitUriToText uri <> " at " <> rev) $ do
    out <-
      readProcessAndLogStderr Debug $
        ignoreGitConfig $
          Cli.proc nixPrefetchGitPath $
            filter
              (/= "")
              [ "--url"
              , T.unpack $ gitUriToText uri
              , "--rev"
              , T.unpack rev
              , if fetchSubmodules then "--fetch-submodules" else ""
              , "--quiet"
              ]

    case parseMaybe (Aeson..: "sha256") =<< Aeson.decodeStrict (encodeUtf8 out) of
      Nothing -> failWith $ "nix-prefetch-git: unrecognized output " <> out
      Just x -> pure x

data ReadThunkError
  = -- | A generic error that can happen while reading a thunk.
    ReadThunkError_UnrecognizedThunk
  | -- | The thunk directory has extraneous paths. The 'Maybe' value
    -- indicates whether we have matched the rest of the files to a valid
    -- specification, and if so, which specification it was.
    ReadThunkError_UnrecognizedPaths (Maybe ThunkSpec) (NonEmpty FilePath)
  | -- | The thunk directory has missing paths.
    ReadThunkError_MissingPaths (NonEmpty FilePath)
  | -- | We could not parse the given file as per the thunk specification.
    -- The 'String' is a parser-specific error message.
    ReadThunkError_UnparseablePtr FilePath String
  | -- | We encountered an 'IOError' while reading the given file.
    ReadThunkError_FileError FilePath IOError
  | -- | We read the given file just fine, but its contents do not match
    -- what was expected for the specification.
    ReadThunkError_FileDoesNotMatch FilePath Text
  | -- | We parsed two valid thunk specs for this directory.
    ReadThunkError_AmbiguousPackedState ThunkSpec ThunkSpec

-- | Pretty-print a 'ReadThunkError' for display to the user
prettyReadThunkError :: ReadThunkError -> Text
prettyReadThunkError =
  \case
    ReadThunkError_UnrecognizedPaths (Just spec) (f :| fs) ->
      -- Limit to five unrecognised paths so that the user doesn't get
      -- utterly spammed:
      T.unlines
        ( "The directory matched spec " <> _thunkSpec_name spec <> ", but the following file(s) are extraneous:"
            : map (("  " <>) . T.pack) (f : take 4 fs)
        )
        <> if length fs > 5 then "... and " <> T.pack (show (length fs - 4)) <> " others." else mempty
    ReadThunkError_MissingPaths (f :| fs) ->
      T.unlines $
        "The following path(s) are missing from the thunk directory:"
          : map (("  " <>) . T.pack) (f : fs)
    ReadThunkError_FileError path ioe -> "I/O error while reading the file " <> T.pack path <> ":\n" <> T.pack (show ioe)
    ReadThunkError_UnparseablePtr path str -> "Syntax error while reading the file " <> T.pack path <> ":\n" <> T.pack str
    ReadThunkError_FileDoesNotMatch path _ -> "The file " <> T.pack path <> " does not have the right contents for this thunk specification."
    ReadThunkError_AmbiguousPackedState speca specb ->
      "The given thunk directory is ambiguous: It matches both " <> _thunkSpec_name speca <> " and " <> _thunkSpec_name specb <> "."
    ReadThunkError_UnrecognizedThunk -> generic
    ReadThunkError_UnrecognizedPaths {} -> generic
  where
    generic = T.pack "The directory did not match any valid thunk specification.\nRun with -v to see why each spec did not match."

-- | Fail due to a 'ReadThunkError' with a standardised error message.
failReadThunkErrorWhile
  :: MonadError NixThunkError m
  => Text
  -- ^ String describing what we were doing.
  -> ReadThunkError
  -- ^ The error
  -> m a
failReadThunkErrorWhile what rte = failWith $ "Failure reading thunk " <> what <> ":\n" <> prettyReadThunkError rte

-- | Did we manage to match the thunk directory to one or more known
-- thunk specs before raising this error?
didMatchThunkSpec :: ReadThunkError -> Bool
didMatchThunkSpec (ReadThunkError_UnrecognizedPaths x _) = isJust x
didMatchThunkSpec ReadThunkError_AmbiguousPackedState {} = True
didMatchThunkSpec _ = False

unpackedDirName :: FilePath
unpackedDirName = "."

-- | The old location of a thunk's attribute cache. No code writes here now,
-- because a packed thunk is also a flake input, and Nix hashes everything
-- inside it. See 'attrCacheDir'. Every spec still allows the directory, so this
-- code still accepts a thunk from an older version.
attrCacheFileName :: FilePath
attrCacheFileName = ".attr-cache"

-- | Writes a thunk file as UTF-8, whatever the locale says. The content comes
-- from the repository that we pack. So a URL, an owner or repository name, and
-- a lock node id can hold non-ASCII characters. The process encoding under
-- @LC_ALL=C@ would reject such a value in the middle of a write.
writeUtf8File :: FilePath -> Text -> IO ()
writeUtf8File path = BSC.writeFile path . encodeUtf8

appendUtf8File :: FilePath -> Text -> IO ()
appendUtf8File path = BSC.appendFile path . encodeUtf8

-- | A path from which our known-good nixpkgs can be fetched.
-- __NOTE__: This path is hardcoded, and only exists so subsumed thunk
-- specs (v7 specifically) can be parsed.
--
-- The v7 loaders substitute this path into a @\"@pinnedNixpkgs@\"@ placeholder,
-- and that placeholder already sits inside Nix string quotes. This code
-- compares each spec's loaders byte for byte against the thunks already on
-- disk. @Data.String.Here.Interpolated@ produced those quotes when it
-- interpolated the path at type 'Text'. Its @toString@ uses @show@ whenever the
-- interpolated value's type differs from the result type, and a @FilePath@
-- always differs.
pinnedNixpkgsPath :: FilePath
pinnedNixpkgsPath = "/nix/store/qjg458n31xk1l6lj26c3b871d4i4is98-source"

-- | Specification for how a file in a thunk version works.
data ThunkFileSpec
  = -- | This file specifies 'ThunkPtr' data
    ThunkFileSpec_Ptr (LBS.ByteString -> Either String ThunkPtr)
  | -- | This file must match the given content exactly
    ThunkFileSpec_FileMatches Text
  | -- | This file is derived from the repository the thunk points at
    ThunkFileSpec_Generated ThunkGeneratedFile
  | -- | Existence of this directory indicates that the thunk is unpacked
    ThunkFileSpec_CheckoutIndicator
  | -- | This directory is an attribute cache
    ThunkFileSpec_AttrCache

-- | A file whose content depends on the repository that a thunk points at, so
-- this code cannot compare it against a fixed string. A read of a thunk only
-- checks that these files are present, and 'createThunk' produces their
-- content. An unpack and a new pack repair a thunk with damaged generated
-- files.
data ThunkGeneratedFile
  = ThunkGeneratedFile_FlakeNix
  | ThunkGeneratedFile_FlakeLock
  deriving stock (Eq, Ord, Show)

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
  => ThunkSpec
  -- ^ 'ThunkSpec' to match against the given files/directory
  -> FilePath
  -- ^ Path to directory
  -> Set FilePath
  -- ^ Set of file paths relative to the given directory
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
        -- A generated file has no fixed content to compare against, so
        -- 'isRequiredFileSpec' below only enforces its presence.
        ThunkFileSpec_Generated _ -> pure Nothing
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
      ThunkFileSpec_Generated _ -> True
      _ -> False

    dirMayExist expectedPath =
      liftIO (doesFileExist (dir </> expectedPath)) >>= \case
        True -> throwError $ ReadThunkError_UnrecognizedPaths Nothing $ expectedPath :| []
        False -> pure ()

    fold1WithM (x :| xs) f = foldM f x xs

readThunkWith
  :: MonadNixThunk m
  => NonEmpty (NonEmpty ThunkSpec) -> FilePath -> m (Either ReadThunkError ThunkData)
readThunkWith specTypes dir = do
  dirFiles <- Set.fromList <$> liftIO (listDirectory dir)
  let specs = concatMap toList (NonEmpty.transpose specTypes) -- Interleave spec types so we try each one in a "fair" ordering
  flip fix specs $ \loop -> \case
    [] -> pure $ Left ReadThunkError_UnrecognizedThunk
    spec : rest ->
      runExceptT (matchThunkSpecToDir spec dir dirFiles) >>= \case
        Left e
          -- If we matched one or more thunk specs, we fail early to tell
          -- the user exactly what's wrong:
          | didMatchThunkSpec e -> pure $ Left e
          -- Otherwise, keep looping:
          | otherwise -> putLog Debug [i|Thunk specification ${_thunkSpec_name spec} did not match ${dir}: ${prettyReadThunkError e}|] *> loop rest
        x@(Right _) -> x <$ putLog Debug [i|Thunk specification ${_thunkSpec_name spec} matched ${dir}|]

-- | Read a packed or unpacked thunk based on predefined thunk specifications.
readThunk :: MonadNixThunk m => FilePath -> m (Either ReadThunkError ThunkData)
readThunk = readThunkWith thunkSpecTypes

parseThunkPtr :: (Aeson.Object -> Aeson.Parser ThunkSource) -> Aeson.Object -> Aeson.Parser ThunkPtr
parseThunkPtr parseSrc v = do
  rev <- v Aeson..: "rev"
  sha256 <- v Aeson..: "sha256"
  src <- parseSrc v
  pure $
    ThunkPtr
      { _thunkPtr_rev =
          ThunkRev
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
  fetchSubmodules <- v Aeson..:! "fetchSubmodules"
  private <- v Aeson..:? "private"
  pure $
    GitHubSource
      { _gitHubSource_owner = owner
      , _gitHubSource_repo = repo
      , _gitHubSource_branch = branch
      , _gitHubSource_fetchSubmodules = fromMaybe False fetchSubmodules
      , _gitHubSource_private = fromMaybe False private
      }

parseGitSource :: Aeson.Object -> Aeson.Parser GitSource
parseGitSource v = do
  rawUrl <- v Aeson..: "url"
  url <- maybe (fail $ "could not parse git URI " <> T.unpack rawUrl) pure $ parseGitUri rawUrl
  branch <- v Aeson..:! "branch"
  fetchSubmodules <- v Aeson..:! "fetchSubmodules"
  private <- v Aeson..:? "private"
  pure $
    GitSource
      { _gitSource_url = url
      , _gitSource_branch = branch
      , _gitSource_fetchSubmodules = fromMaybe False fetchSubmodules
      , _gitSource_private = fromMaybe False private
      }

overwriteThunk :: MonadNixThunk m => ThunkConfig -> FilePath -> ThunkPtr -> m ()
overwriteThunk config target thunk = do
  -- Ensure that this directory is a valid thunk (i.e. so we aren't losing any data)
  readThunk target >>= \case
    Left e -> failReadThunkErrorWhile "while overwriting" e
    Right _ -> pure ()

  -- This code assembles the new thunk beside the old one, and it replaces the
  -- old thunk only after the new one is complete. A write of a thunk calls the
  -- network to generate its flake files. A failure in the middle would
  -- otherwise leave a directory without flake files. Such a directory matches
  -- the previous thunk version, because the loaders are identical. The format
  -- would return to the old version in silence, and the update would not report
  -- a failure.
  let (thunkParent, thunkName) = splitFileName target
  withTempDirectory thunkParent thunkName $ \tmpThunk -> do
    let staged = tmpThunk </> "packed"
    createThunkWithSpec staged (thunkSpecFor config thunk) (Just thunk)
    liftIO $ do
      removePathForcibly target
      renameDirectory staged target

-- | The format that this code gives a new thunk. The default is the newest
-- format. When the caller asks for no flakes, the result is the newest format
-- that carries no flake files.
--
-- This code chooses by that property, and it does not choose by name, so a
-- later spec needs no change here.
thunkSpecFor :: ThunkConfig -> ThunkPtr -> ThunkSpec
thunkSpecFor config thunk
  | _thunkConfig_noFlake config = fromMaybe newest $ find (not . specHasFlakeFiles) specs
  | otherwise = newest
  where
    specs = thunkPtrToSpecs thunk
    newest = NonEmpty.head specs

thunkPtrToSpec :: ThunkPtr -> ThunkSpec
thunkPtrToSpec = NonEmpty.head . thunkPtrToSpecs

thunkPtrToSpecs :: ThunkPtr -> NonEmpty ThunkSpec
thunkPtrToSpecs thunk = case _thunkPtr_source thunk of
  ThunkSource_GitHub _ -> gitHubThunkSpecs
  ThunkSource_Git _ -> gitThunkSpecs

-- It's important that formatting be very consistent here, because
-- otherwise when people update thunks, their patches will be messy
encodeThunkPtrData :: ThunkPtr -> LBS.ByteString
encodeThunkPtrData (ThunkPtr rev src) = case src of
  ThunkSource_GitHub s ->
    encodePretty' githubCfg $
      Aeson.object $
        catMaybes
          [ Just $ "owner" .= _gitHubSource_owner s
          , Just $ "repo" .= _gitHubSource_repo s
          , ("branch" .=) <$> _gitHubSource_branch s
          , Just $ "rev" .= refToHexString (_thunkRev_commit rev)
          , Just $ "sha256" .= _thunkRev_nixSha256 rev
          , Just $ "fetchSubmodules" .= _gitHubSource_fetchSubmodules s
          , Just $ "private" .= _gitHubSource_private s
          ]
  ThunkSource_Git s ->
    encodePretty' plainGitCfg $
      Aeson.object $
        catMaybes
          [ Just $ "url" .= gitUriToText (_gitSource_url s)
          , Just $ "rev" .= refToHexString (_thunkRev_commit rev)
          , ("branch" .=) <$> _gitSource_branch s
          , Just $ "sha256" .= _thunkRev_nixSha256 rev
          , Just $ "fetchSubmodules" .= _gitSource_fetchSubmodules s
          , Just $ "private" .= _gitSource_private s
          ]
  where
    githubCfg =
      defConfig
        { confIndent = Spaces 2
        , confCompare =
            keyOrder
              [ "owner"
              , "repo"
              , "branch"
              , "fetchSubmodules"
              , "private"
              , "rev"
              , "sha256"
              ]
              <> compare
        , confTrailingNewline = True
        }
    plainGitCfg =
      defConfig
        { confIndent = Spaces 2
        , confCompare =
            keyOrder
              [ "url"
              , "rev"
              , "sha256"
              , "private"
              , "fetchSubmodules"
              ]
              <> compare
        , confTrailingNewline = True
        }

createThunk' :: MonadNixThunk m => ThunkCreateConfig -> m ()
createThunk' config = do
  newThunkPtr <-
    thunkCreateSourcePtr
      (_thunkCreateConfig_uri config)
      (_thunkConfig_private $ _thunkCreateConfig_config config)
      (_thunkConfig_submodules $ _thunkCreateConfig_config config)
      (untagName <$> _thunkCreateConfig_branch config)
      (T.pack . show <$> _thunkCreateConfig_rev config)
  let trailingDirectoryName = reverse . takeWhile (/= '/') . dropWhile (== '/') . reverse
      dropDotGit :: FilePath -> FilePath
      dropDotGit origName = fromMaybe origName $ stripExtension "git" origName

      defaultDestinationForGitUri :: GitUri -> FilePath
      defaultDestinationForGitUri = dropDotGit . trailingDirectoryName . T.unpack . URI.render . unGitUri

  destination <- case _thunkCreateConfig_uri config of
    ThunkCreateSource_Absolute uri -> pure $ fromMaybe (defaultDestinationForGitUri uri) $ _thunkCreateConfig_destination config
    ThunkCreateSource_Relative _ -> case _thunkCreateConfig_destination config of
      Nothing -> failWith "When using a relative path as the thunk source, the destination path must be specified."
      Just dst -> pure dst
  createThunkWithSpec
    destination
    (thunkSpecFor (_thunkCreateConfig_config config) newThunkPtr)
    (Just newThunkPtr)

-- | Writes a thunk in the newest format that its pointer allows.
createThunk :: MonadNixThunk m => FilePath -> Either ThunkSpec ThunkPtr -> m ()
createThunk target = \case
  Left spec -> createThunkWithSpec target spec Nothing
  Right ptr -> createThunkWithSpec target (thunkPtrToSpec ptr) (Just ptr)

-- | Writes a thunk in a given format.
--
-- The caller chooses the format, and the pointer does not determine it.
-- @--no-flake@ asks for a thunk one format older than the newest format. An
-- unpack keeps the format that the thunk already had.
createThunkWithSpec :: MonadNixThunk m => FilePath -> ThunkSpec -> Maybe ThunkPtr -> m ()
createThunkWithSpec target spec mPtr = do
  isdir <- liftIO $ doesDirectoryExist target
  when isdir $ do
    isempty <- null <$> liftIO (listDirectory target)
    unless isempty $ failWith $ "Refusing to create thunk in non-empty directory " <> T.pack target

  ifor_ (_thunkSpec_files spec) $ \path -> \case
    ThunkFileSpec_FileMatches content -> withReadyPath path $ \p -> liftIO $ writeUtf8File p content
    -- Without a pointer, this code cannot write the pointer file.
    ThunkFileSpec_Ptr _ -> for_ mPtr $ \ptr ->
      withReadyPath path $ \p -> liftIO $ LBS.writeFile p (encodeThunkPtrData ptr)
    -- This code writes these files below, because it cannot fetch the
    -- repository that their content comes from until the loaders above exist.
    ThunkFileSpec_Generated _ -> pure ()
    _ -> pure ()

  -- Without a pointer, this code cannot fetch the source.
  for_ mPtr $ \ptr ->
    when (specHasFlakeFiles spec) $ writeThunkFlakeFiles target ptr
  where
    withReadyPath path f = do
      let fullPath = target </> path
      putLog Debug $ "Writing thunk file " <> T.pack fullPath
      liftIO $ createDirectoryIfMissing True $ takeDirectory fullPath
      f fullPath

specHasFlakeFiles :: ThunkSpec -> Bool
specHasFlakeFiles = any isGenerated . _thunkSpec_files
  where
    isGenerated = \case
      ThunkFileSpec_Generated _ -> True
      _ -> False

-- | Generates the flake files of a packed thunk.
writeThunkFlakeFiles :: MonadNixThunk m => FilePath -> ThunkPtr -> m ()
writeThunkFlakeFiles target ptr = do
  let srcRef = thunkPtrToFlakeRef ptr
  fetched <- fetchFlakeRef srcRef
  let srcRefs = Flake.sourceNodeRefs srcRef $ _fetchedFlakeRef_locked fetched
  liftIO (doesFileExist $ flakeNixPath $ _fetchedFlakeRef_outPath fetched) >>= \case
    False -> writeSourceOnlyFlakeFiles target srcRef srcRefs
    True -> do
      lock <- upstreamFlakeLock $ _fetchedFlakeRef_outPath fetched
      writeFlattenedFlakeFiles target $ Flake.flattenLock srcRefs lock

-- | The flake files of a thunk whose upstream is not itself a flake. This code
-- has nothing to flatten, so the flake exposes only the fetched source.
writeSourceOnlyFlakeFiles :: MonadNixThunk m => FilePath -> Flake.FlakeRef -> Flake.NodeRefs -> m ()
writeSourceOnlyFlakeFiles target srcRef srcRefs = do
  liftIO $ do
    writeUtf8File (flakeNixPath target) $ Flake.renderSourceOnlyFlakeNix srcRef
    LBS.writeFile (flakeLockPath target) $ Flake.renderSourceOnlyFlakeLock srcRefs
  lockThunkFlake target

-- | The flake files of a thunk whose upstream is a flake.
writeFlattenedFlakeFiles :: MonadNixThunk m => FilePath -> Flake.FlattenedFlake -> m ()
writeFlattenedFlakeFiles target flattened = do
  liftIO $ writeUtf8File (flakeNixPath target) $ Flake.renderFlakeNix flattened
  -- Upstream's lock already records what every input of the generated flake
  -- resolves to, so this code writes the thunk's own lock from it. The generated
  -- flake can leave an input for upstream's lock to settle. This file then does
  -- not record the inputs, and this code writes nothing.
  if Flake.flattenedFlake_complete flattened
    then liftIO $ LBS.writeFile (flakeLockPath target) $ Flake.renderFlakeLock flattened
    else
      putLog Debug $
        "Some inputs of "
          <> T.pack target
          <> " could not be restated, so locking it has to resolve them."
  lockThunkFlake target

-- | Asks Nix to lock the generated flake.
--
-- A lock already sits beside the flake, and that lock accounts for every input.
-- So Nix reads the two files, finds no difference, and writes nothing. Without
-- that lock, Nix would resolve one input for each node of upstream's lock. This
-- code runs the lock command anyway, because the command is the only reader of
-- the generated flake. Nix can reject the flake here, and without this run
-- nobody would evaluate the flake until a consumer depended on it.
lockThunkFlake :: MonadNixThunk m => FilePath -> m ()
lockThunkFlake target = do
  before <- liftIO $ readFileMaybe $ flakeLockPath target
  nixFlakeLock target
  after <- liftIO $ readFileMaybe $ flakeLockPath target
  when (isJust before && before /= after) $
    putLog Warning $
      "The lock written for "
        <> T.pack target
        <> " did not survive `nix flake lock`, which has replaced it. The thunk"
        <> " is correct, but its inputs were resolved rather than restated."

-- | The repository that a reference points at, after a fetch.
data FetchedFlakeRef = FetchedFlakeRef
  { _fetchedFlakeRef_outPath :: FilePath
  , _fetchedFlakeRef_locked :: Flake.FlakeRef
  -- ^ The attributes that the fetch discovered and the reference did not hold.
  -- A lock records these attributes in addition to the reference.
  }

instance Aeson.FromJSON FetchedFlakeRef where
  parseJSON = Aeson.withObject "FetchedFlakeRef" $ \o ->
    FetchedFlakeRef
      <$> o Aeson..: "path"
      <*> o Aeson..: "locked"

-- | Fetches the repository that a reference points at.
--
-- This code uses the same fetcher as the generated flake, and it does not use
-- the thunk's own @thunk.nix@. So a pack reports a reference that Nix cannot
-- resolve, and a later user of the thunk does not meet that failure. The
-- reference pins the revision, so Nix caches the fetch.
fetchFlakeRef :: MonadNixThunk m => Flake.FlakeRef -> m FetchedFlakeRef
fetchFlakeRef srcRef = do
  out <-
    withExitFailMessage ("nix eval: Failed to fetch " <> Flake.renderFlakeRefExpr srcRef) $
      readProcessQuietly $
        nixProc $
          fetchFlakeRefArgs srcRef
  case Aeson.eitherDecodeStrict $ encodeUtf8 $ T.strip out of
    Left e -> failWith $ "Could not read what fetching " <> Flake.renderFlakeRefExpr srcRef <> " produced:\n" <> T.pack e
    Right fetched -> pure fetched

fetchFlakeRefArgs :: Flake.FlakeRef -> [String]
fetchFlakeRefArgs srcRef = ["eval", "--impure", "--raw", "--expr", T.unpack $ fetchTreeExpr srcRef]

-- | The expression that fetches a reference and reports what a lock records
-- about it.
--
-- The expression reports the store path as @path@, and not as @outPath@.
-- @toJSON@ coerces an attribute set that holds an @outPath@ to that one string,
-- exactly as @toString@ does. The result loses every other attribute.
fetchTreeExpr :: Flake.FlakeRef -> Text
fetchTreeExpr srcRef =
  "let tree = builtins.fetchTree "
    <> Flake.renderFlakeRefExpr srcRef
    <> "; in builtins.toJSON { path = tree.outPath; locked = builtins.intersectAttrs "
    <> lockedAttrsExpr
    <> " tree; }"

-- | The attributes of a fetched tree that belong in a lock. @fetchTree@ returns
-- other attributes. Each one is the tree itself, or it restates these
-- attributes.
lockedAttrsExpr :: Text
lockedAttrsExpr = "{ lastModified = null; narHash = null; rev = null; revCount = null; }"

-- | Upstream's own lock. That lock pins the revisions that the thunk
-- reproduces. An upstream without a lock pins nothing, so this code must
-- resolve upstream's inputs itself.
upstreamFlakeLock :: MonadNixThunk m => FilePath -> m Flake.FlakeLock
upstreamFlakeLock srcPath = do
  stored <- liftIO $ try @IOError $ BSC.readFile $ flakeLockPath srcPath
  case stored of
    Right bytes -> either unparseable pure $ Aeson.eitherDecodeStrict bytes
    Left e
      | not (isDoesNotExistError e) ->
          failWith $
            "Could not read the "
              <> T.pack flakeLockFileName
              <> " of "
              <> T.pack srcPath
              <> ":\n"
              <> T.pack (show e)
    Left _ -> do
      putLog Warning $
        T.pack srcPath
          <> " has no "
          <> T.pack flakeLockFileName
          <> "; its inputs will be pinned as of now rather than as upstream pinned them."
      flakeMetadata_locks <$> nixFlakeMetadata srcPath
  where
    unparseable e =
      failWith $
        "Could not parse the " <> T.pack flakeLockFileName <> " of " <> T.pack srcPath <> ":\n" <> T.pack e

newtype FlakeMetadata = FlakeMetadata
  { flakeMetadata_locks :: Flake.FlakeLock
  }

instance Aeson.FromJSON FlakeMetadata where
  parseJSON = Aeson.withObject "FlakeMetadata" $ \o -> FlakeMetadata <$> o Aeson..: "locks"

nixFlakeMetadata :: MonadNixThunk m => FilePath -> m FlakeMetadata
nixFlakeMetadata srcPath = do
  out <-
    withExitFailMessage ("nix flake metadata: Failed to resolve the inputs of " <> T.pack srcPath) $
      readProcessQuietly $
        nixProc $
          nixFlakeMetadataArgs srcPath
  case Aeson.eitherDecodeStrict $ encodeUtf8 out of
    Right v -> pure v
    Left e -> failWith $ "nix flake metadata: unrecognized output:\n" <> T.pack e

nixFlakeMetadataArgs :: FilePath -> [String]
nixFlakeMetadataArgs srcPath = ["flake", "metadata", "--json", "--no-write-lock-file", flakePathRef srcPath]

nixFlakeLock :: MonadNixThunk m => FilePath -> m ()
nixFlakeLock target =
  withExitFailMessage failureMessage $
    callProcessQuietly $
      nixProc $
        nixFlakeLockArgs target
  where
    -- A lock resolves every input that the generated flake declares, and that
    -- is one input for each node of upstream's own lock. So a pin that this
    -- machine cannot reach fails here.
    failureMessage =
      "nix flake lock: Failed to lock the flake of thunk "
        <> T.pack target
        <> ".\nLocking has to resolve every input of the repository this thunk"
        <> " points at, so this fails if any of them is unreachable from here."

nixFlakeLockArgs :: FilePath -> [String]
nixFlakeLockArgs target = ["flake", "lock", flakePathRef target]

-- | Captures a process's stdout. The process's stderr goes to the log at
-- 'Debug', because the nix tools write progress to stderr even when nothing is
-- wrong.
readProcessQuietly :: MonadNixThunk m => ProcessSpec -> m Text
readProcessQuietly = readProcessAndLogStderr Debug

-- | Runs a process for its effect. Both of the process's streams go to the log
-- at 'Debug', for the same reason as 'readProcessQuietly'.
callProcessQuietly :: MonadNixThunk m => ProcessSpec -> m ()
callProcessQuietly = callProcessAndLogOutput (Debug, Debug)

-- | A nix invocation with the flake features on. Every command that the flake
-- files need sits behind those features.
nixProc :: [String] -> ProcessSpec
nixProc args = nixRawProc $ flakeArgs <> args

nixRawProc :: [String] -> ProcessSpec
nixRawProc = Cli.proc nixExePath

-- | A pack of a thunk must not depend on the user's Nix configuration, so these
-- commands request the features that they need.
flakeArgs :: [String]
flakeArgs = ["--extra-experimental-features", "nix-command flakes"]

-- | Names a directory in a form that Nix reads as a path.
--
-- Nix matches its flake-id syntax before its path syntax, so Nix looks up a
-- bare relative argument like @dep\/foo@ in the flake registries. Without the
-- prefix, Nix also resolves a directory inside a git work tree through that
-- repository. Nix then sees only tracked files, so it misses the @flake.nix@
-- that this code just wrote.
flakePathRef :: FilePath -> String
flakePathRef = ("path:" <>)

nixExePath :: FilePath
nixExePath = $(staticWhich "nix")

-- | The flake reference for the repository that a thunk points at.
--
-- The @github@ fetcher cannot fetch submodules, and it cannot authenticate
-- against a private repository. So both of those cases use the plain @git@
-- fetcher over the ssh URL that 'forgetGithub' produces.
thunkPtrToFlakeRef :: ThunkPtr -> Flake.FlakeRef
thunkPtrToFlakeRef (ThunkPtr rev src) = case src of
  ThunkSource_GitHub s
    | _gitHubSource_private s -> gitRef rev $ forgetGithub True s
    | _gitHubSource_fetchSubmodules s -> gitRef rev $ forgetGithub False s
    | otherwise -> githubRef rev s
  ThunkSource_Git s -> gitRef rev s

-- | The @github@ form of a thunk's reference.
--
-- This form carries no @ref@. The @github@ fetcher rejects a reference that
-- holds both a revision and a branch. The revision alone identifies the tree,
-- because GitHub serves an archive of any revision, whatever the branch.
githubRef :: ThunkRev -> GitHubSource -> Flake.FlakeRef
githubRef rev s =
  flakeRef
    [ ("type", flakeRefStr "github")
    , ("owner", flakeRefStr $ untagName $ _gitHubSource_owner s)
    , ("repo", flakeRefStr $ untagName $ _gitHubSource_repo s)
    , ("rev", flakeRefStr $ commitText rev)
    ]

-- | The @git@ form of a thunk's reference.
gitRef :: ThunkRev -> GitSource -> Flake.FlakeRef
gitRef rev s =
  flakeRef $
    catMaybes
      [ Just ("type", flakeRefStr "git")
      , Just ("url", flakeRefStr $ flakeUriToText $ _gitSource_url s)
      , Just ("rev", flakeRefStr $ commitText rev)
      , Just $ case _gitSource_branch s of
          Just b -> ("ref", flakeRefStr $ untagName b)
          -- Without a branch, Nix does not have to reach the revision from the
          -- default branch. The v9 loader applies the same rule:
          -- `allRefs = branch == null`.
          Nothing -> ("allRefs", Flake.FlakeRefValue_Bool True)
      , ("submodules", Flake.FlakeRefValue_Bool True) <$ guard (_gitSource_fetchSubmodules s)
      ]

flakeRef :: [(Text, Flake.FlakeRefValue)] -> Flake.FlakeRef
flakeRef = Flake.FlakeRef . Map.fromList . fmap (first Flake.AttrName)

flakeRefStr :: Text -> Flake.FlakeRefValue
flakeRefStr = Flake.FlakeRefValue_String

commitText :: ThunkRev -> Text
commitText rev = T.pack $ refToHexString $ _thunkRev_commit rev

updateThunkToLatest :: MonadNixThunk m => ThunkUpdateConfig -> FilePath -> m ()
updateThunkToLatest cfg target = do
  withSpinner' ("Updating thunk " <> T.pack target <> " to latest") (pure $ const $ "Thunk " <> T.pack target <> " updated to latest") $ do
    checkThunkDirectory target
    readThunk target >>= \case
      Left err -> failReadThunkErrorWhile "during an update" err
      Right c -> case c of
        ThunkData_Checkout -> failWith [i|Thunk located at ${target} is unpacked. Use 'ob thunk pack' on the desired directory and then try 'ob thunk update' again.|]
        ThunkData_Packed _ t -> case _thunkUpdateConfig_ref cfg of
          Just ref -> do
            newThunkPtr <-
              uriThunkPtr
                (_gitSource_url $ thunkSourceToGitSource $ _thunkPtr_source t)
                (_thunkConfig_private $ _thunkUpdateConfig_thunk cfg)
                ( _thunkConfig_submodules (_thunkUpdateConfig_thunk cfg)
                    <|> Just (thunkSourceFetchSubmodules $ _thunkPtr_source t)
                )
                (_thunkUpdateConfig_branch cfg)
                (Just ref)
            overwriteThunk (_thunkUpdateConfig_thunk cfg) target newThunkPtr
          Nothing -> do
            let newSrc :: ThunkSource
                newSrc = case _thunkUpdateConfig_branch cfg of
                  Nothing -> _thunkPtr_source t
                  Just b -> setThunkSourceBranch (Just $ N b) $ _thunkPtr_source t
            rev <- getLatestRev newSrc
            overwriteThunk (_thunkUpdateConfig_thunk cfg) target $
              modifyThunkPtrByConfig (_thunkUpdateConfig_thunk cfg) $
                ThunkPtr
                  { _thunkPtr_source = newSrc
                  , _thunkPtr_rev = rev
                  }

-- | All recognized github standalone loaders, ordered from newest to oldest.
-- This tool will only ever produce the newest one when it writes a thunk.
gitHubThunkSpecs :: NonEmpty ThunkSpec
gitHubThunkSpecs =
  gitHubThunkSpecV9
    :| [ gitHubThunkSpecV8
       , gitHubThunkSpecV7
       , gitHubThunkSpecV6
       , gitHubThunkSpecV5
       , gitHubThunkSpecV4
       , gitHubThunkSpecV3
       , gitHubThunkSpecV2
       , gitHubThunkSpecV1
       ]

gitHubThunkSpecV1 :: ThunkSpec
gitHubThunkSpecV1 =
  legacyGitHubThunkSpec
    "github-v1"
    "import ((import <nixpkgs> {}).fetchFromGitHub (builtins.fromJSON (builtins.readFile ./github.json)))"

gitHubThunkSpecV2 :: ThunkSpec
gitHubThunkSpecV2 =
  legacyGitHubThunkSpec
    "github-v2"
    -- TODO: Add something about how to get more info on NixThunk, etc.
    """
    # DO NOT HAND-EDIT THIS FILE
    import ((import <nixpkgs> {}).fetchFromGitHub (
      let json = builtins.fromJSON (builtins.readFile ./github.json);
      in { inherit (json) owner repo rev sha256;
           private = json.private or false;
         }
    ))
    """

gitHubThunkSpecV3 :: ThunkSpec
gitHubThunkSpecV3 =
  legacyGitHubThunkSpec
    "github-v3"
    """
    # DO NOT HAND-EDIT THIS FILE
    let
      fetch = { private ? false, ... }@args: if private && builtins.hasAttr "fetchGit" builtins
        then fetchFromGitHubPrivate args
        else (import <nixpkgs> {}).fetchFromGitHub (builtins.removeAttrs args ["branch"]);
      fetchFromGitHubPrivate =
        { owner, repo, rev, branch ? null, name ? null, sha256 ? null, private ? false
        , fetchSubmodules ? false, githubBase ? "github.com", ...
        }: assert !fetchSubmodules;
          builtins.fetchGit ({
            url = "ssh://git@${githubBase}/${owner}/${repo}.git";
            inherit rev;
          }
          // (if branch == null then {} else { ref = branch; })
          // (if name == null then {} else { inherit name; }));
    in import (fetch (builtins.fromJSON (builtins.readFile ./github.json)))
    """

gitHubThunkSpecV4 :: ThunkSpec
gitHubThunkSpecV4 =
  legacyGitHubThunkSpec
    "github-v4"
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
      if !fetchSubmodules && !private then builtins.fetchTarball {
        url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
      } else (import <nixpkgs> {}).fetchFromGitHub {
        inherit owner repo rev sha256 fetchSubmodules private;
      };
    in import (fetch (builtins.fromJSON (builtins.readFile ./github.json)))
    """

legacyGitHubThunkSpec :: Text -> Text -> ThunkSpec
legacyGitHubThunkSpec name loader =
  ThunkSpec name $
    Map.fromList
      [ ("default.nix", ThunkFileSpec_FileMatches $ T.strip loader)
      , ("github.json", ThunkFileSpec_Ptr parseGitHubJsonBytes)
      , (attrCacheFileName, ThunkFileSpec_AttrCache)
      , (".git", ThunkFileSpec_CheckoutIndicator)
      ]

gitHubThunkSpecV5 :: ThunkSpec
gitHubThunkSpecV5 =
  mkThunkSpec
    "github-v5"
    "github.json"
    parseGitHubJsonBytes
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
      if !fetchSubmodules && !private then builtins.fetchTarball {
        url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
      } else (import <nixpkgs> {}).fetchFromGitHub {
        inherit owner repo rev sha256 fetchSubmodules private;
      };
      json = builtins.fromJSON (builtins.readFile ./github.json);
    in fetch json
    """

-- | See 'gitHubThunkSpecV7'.
--
-- __NOTE__: v6 spec thunks are broken! They import the pinned nixpkgs
-- in an incorrect way. GitHub thunks for public repositories with no
-- submodules will still work, but update as soon as possible.
gitHubThunkSpecV6 :: ThunkSpec
gitHubThunkSpecV6 =
  mkThunkSpec
    "github-v6"
    "github.json"
    parseGitHubJsonBytes
    """
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
    """

-- | Specification for GitHub thunks which use a specific, pinned
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@. The "v7" specs ensure that thunks can be fetched even
-- when @NIX_PATH@ is unset.
gitHubThunkSpecV7 :: ThunkSpec
gitHubThunkSpecV7 =
  mkThunkSpec
    "github-v7"
    "github.json"
    parseGitHubJsonBytes
    $ T.replace
      "@pinnedNixpkgs@"
      (T.pack pinnedNixpkgsPath)
      """
      # DO NOT HAND-EDIT THIS FILE
      let fetch = { private ? false, fetchSubmodules ? false, owner, repo, rev, sha256, ... }:
        if !fetchSubmodules && !private then builtins.fetchTarball {
          url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"; inherit sha256;
        } else (import "@pinnedNixpkgs@" {}).fetchFromGitHub {
          inherit owner repo rev sha256 fetchSubmodules private;
        };
        json = builtins.fromJSON (builtins.readFile ./github.json);
      in fetch json
      """

-- | Specification for GitHub thunks which use a specific, pinned
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@.
--
-- Unlike 'gitHubThunKSpecV7', this thunk specification fetches the
-- nixpkgs tarball from GitHub, so it will fail on environments without
-- a network connection.
gitHubThunkSpecV8 :: ThunkSpec
gitHubThunkSpecV8 = mkThunkSpec "github-v8" "github.json" parseGitHubJsonBytes gitHubLoaderV8

-- | This spec adds the generated flake files to 'gitHubThunkSpecV8'. The loader
-- stays the same, so a v9 thunk fetches exactly like a v8 thunk, and a consumer
-- can also use it as a flake input.
gitHubThunkSpecV9 :: ThunkSpec
gitHubThunkSpecV9 = mkFlakeThunkSpec "github-v9" "github.json" parseGitHubJsonBytes gitHubLoaderV8

-- | 'gitHubThunkSpecV8' and 'gitHubThunkSpecV9' both use this loader.
gitHubLoaderV8 :: Text
gitHubLoaderV8 =
  """
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
  """

parseGitHubJsonBytes :: LBS.ByteString -> Either String ThunkPtr
parseGitHubJsonBytes = parseJsonObject $ parseThunkPtr $ \v ->
  ThunkSource_GitHub <$> parseGitHubSource v <|> ThunkSource_Git <$> parseGitSource v

gitThunkSpecs :: NonEmpty ThunkSpec
gitThunkSpecs =
  gitThunkSpecV10
    :| [ gitThunkSpecV9
       , gitThunkSpecV8
       , gitThunkSpecV7
       , gitThunkSpecV6
       , gitThunkSpecV5
       , gitThunkSpecV4
       , gitThunkSpecV3
       , gitThunkSpecV2
       , gitThunkSpecV1
       ]

gitThunkSpecV1 :: ThunkSpec
gitThunkSpecV1 =
  legacyGitThunkSpec
    "git-v1"
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetchGit = {url, rev, ref ? null, branch ? null, sha256 ? null, fetchSubmodules ? null}:
      assert !fetchSubmodules; (import <nixpkgs> {}).fetchgit { inherit url rev sha256; };
    in import (fetchGit (builtins.fromJSON (builtins.readFile ./git.json)))
    """

gitThunkSpecV2 :: ThunkSpec
gitThunkSpecV2 =
  legacyGitThunkSpec
    "git-v2"
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetchGit = {url, rev, ref ? null, branch ? null, sha256 ? null, fetchSubmodules ? null}:
      if builtins.hasAttr "fetchGit" builtins
        then builtins.fetchGit ({ inherit url rev; } // (if branch == null then {} else { ref = branch; }))
        else abort "Plain Git repositories are only supported on nix 2.0 or higher.";
    in import (fetchGit (builtins.fromJSON (builtins.readFile ./git.json)))
    """

-- This loader has a bug because @builtins.fetchGit@ is not given a @ref@
-- and will fail to find commits without this because it does shallow clones.
gitThunkSpecV3 :: ThunkSpec
gitThunkSpecV3 =
  legacyGitThunkSpec
    "git-v3"
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetch = {url, rev, ref ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
      let realUrl = let firstChar = builtins.substring 0 1 url; in
        if firstChar == "/" then /. + url
        else if firstChar == "." then ./. + url
        else url;
      in if !fetchSubmodules && private then builtins.fetchGit {
        url = realUrl; inherit rev;
      } else (import <nixpkgs> {}).fetchgit {
        url = realUrl; inherit rev sha256;
      };
    in import (fetch (builtins.fromJSON (builtins.readFile ./git.json)))
    """

gitThunkSpecV4 :: ThunkSpec
gitThunkSpecV4 =
  legacyGitThunkSpec
    "git-v4"
    """
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
    in import (fetch (builtins.fromJSON (builtins.readFile ./git.json)))
    """

legacyGitThunkSpec :: Text -> Text -> ThunkSpec
legacyGitThunkSpec name loader =
  ThunkSpec name $
    Map.fromList
      [ ("default.nix", ThunkFileSpec_FileMatches $ T.strip loader)
      , ("git.json", ThunkFileSpec_Ptr parseGitJsonBytes)
      , (attrCacheFileName, ThunkFileSpec_AttrCache)
      , (".git", ThunkFileSpec_CheckoutIndicator)
      ]

gitThunkSpecV5 :: ThunkSpec
gitThunkSpecV5 =
  mkThunkSpec
    "git-v5"
    "git.json"
    parseGitJsonBytes
    """
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
    """

-- | See 'gitThunkSpecV7'.
-- __NOTE__: v6 spec thunks are broken! They import the pinned nixpkgs
-- in an incorrect way. GitHub thunks for public repositories with no
-- submodules will still work, but update as soon as possible.
gitThunkSpecV6 :: ThunkSpec
gitThunkSpecV6 =
  mkThunkSpec
    "git-v6"
    "git.json"
    parseGitJsonBytes
    """
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
    """

-- | Specification for Git thunks which use a specific, pinned version
-- of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@. The "v7" specs ensure that thunks can be fetched even
-- when @NIX_PATH@ is unset.
gitThunkSpecV7 :: ThunkSpec
gitThunkSpecV7 =
  mkThunkSpec
    "git-v7"
    "git.json"
    parseGitJsonBytes
    $ T.replace
      "@pinnedNixpkgs@"
      (T.pack pinnedNixpkgsPath)
      """
      # DO NOT HAND-EDIT THIS FILE
      let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
        let realUrl = let firstChar = builtins.substring 0 1 url; in
          if firstChar == "/" then /. + url
          else if firstChar == "." then ./. + url
          else url;
        in if !fetchSubmodules && private then builtins.fetchGit {
          url = realUrl; inherit rev;
          ${if branch == null then null else "ref"} = branch;
        } else (import "@pinnedNixpkgs@" {}).fetchgit {
          url = realUrl; inherit rev sha256;
        };
        json = builtins.fromJSON (builtins.readFile ./git.json);
      in fetch json
      """

-- | Specification for Git thunks which use a specific, pinned version
-- version of nixpkgs for fetching, rather than using @<nixpkgs>@ from
-- @NIX_PATH@.
--
-- Unlike 'gitHubThunKSpecV7', this thunk specification fetches the
-- nixpkgs tarball from GitHub, so it will fail on environments without
-- a network connection.
gitThunkSpecV8 :: ThunkSpec
gitThunkSpecV8 =
  mkThunkSpec
    "git-v8"
    "git.json"
    parseGitJsonBytes
    """
    # DO NOT HAND-EDIT THIS FILE
    let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
      let realUrl = let firstChar = builtins.substring 0 1 url; in
        if firstChar == "/" then /. + url
        else if firstChar == "." then ./. + url
        else url;
      in if !fetchSubmodules && private then builtins.fetchGit {
        url = realUrl; inherit rev;
        ${if branch == null then null else "ref"} = branch;
      } else (import (builtins.fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
      sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
    }) {}).fetchgit {
        url = realUrl; inherit rev sha256;
      };
      json = builtins.fromJSON (builtins.readFile ./git.json);
    in fetch json
    """

-- | Improves V8 by supporting retrieving revs from any branch, when a branch is not provided
-- Previously, it would only work for revs that were present on the default branch
gitThunkSpecV9 :: ThunkSpec
gitThunkSpecV9 = mkThunkSpec "git-v9" "git.json" parseGitHubJsonBytes gitLoaderV9

-- | This spec adds the generated flake files to 'gitThunkSpecV9'. The loader
-- stays the same, so a v10 thunk fetches exactly like a v9 thunk, and a
-- consumer can also use it as a flake input.
gitThunkSpecV10 :: ThunkSpec
gitThunkSpecV10 = mkFlakeThunkSpec "git-v10" "git.json" parseGitHubJsonBytes gitLoaderV9

-- | 'gitThunkSpecV9' and 'gitThunkSpecV10' both use this loader.
gitLoaderV9 :: Text
gitLoaderV9 =
  """
  # DO NOT HAND-EDIT THIS FILE
  let fetch = {url, rev, branch ? null, sha256 ? null, fetchSubmodules ? false, private ? false, ...}:
    let realUrl = let firstChar = builtins.substring 0 1 url; in
      if firstChar == "/" then /. + url
      else if firstChar == "." then ./. + url
      else url;
    in if !fetchSubmodules && private then builtins.fetchGit {
      url = realUrl; inherit rev;
      ${if branch == null then null else "ref"} = branch;
      allRefs = branch == null;
    } else (import (builtins.fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/3aad50c30c826430b0270fcf8264c8c41b005403.tar.gz";
      sha256 = "0xwqsf08sywd23x0xvw4c4ghq0l28w2ki22h0bdn766i16z9q2gr";
    }) {}).fetchgit {
      url = realUrl; inherit rev sha256;
    };
    json = builtins.fromJSON (builtins.readFile ./git.json);
  in fetch json
  """

parseGitJsonBytes :: LBS.ByteString -> Either String ThunkPtr
parseGitJsonBytes = parseJsonObject $ parseThunkPtr $ fmap ThunkSource_Git . parseGitSource

-- | A spec whose packed thunk is also a flake. 'mkThunkSpec' builds a spec
-- without the flake files.
--
-- The generated @flake.nix@ exposes the inputs of the repository that the thunk
-- points at, and the generated @flake.lock@ pins those inputs.
mkFlakeThunkSpec :: Text -> FilePath -> (LBS.ByteString -> Either String ThunkPtr) -> Text -> ThunkSpec
mkFlakeThunkSpec name jsonFileName parser srcNix =
  let spec = mkThunkSpec name jsonFileName parser srcNix
  in spec
       { _thunkSpec_files =
           _thunkSpec_files spec
             <> Map.fromList
               [ (flakeNixFileName, ThunkFileSpec_Generated ThunkGeneratedFile_FlakeNix)
               , (flakeLockFileName, ThunkFileSpec_Generated ThunkGeneratedFile_FlakeLock)
               ]
       }

flakeNixPath :: FilePath -> FilePath
flakeNixPath dir = dir </> flakeNixFileName

flakeLockPath :: FilePath -> FilePath
flakeLockPath dir = dir </> flakeLockFileName

flakeNixFileName :: FilePath
flakeNixFileName = "flake.nix"

flakeLockFileName :: FilePath
flakeLockFileName = "flake.lock"

mkThunkSpec :: Text -> FilePath -> (LBS.ByteString -> Either String ThunkPtr) -> Text -> ThunkSpec
mkThunkSpec name jsonFileName parser srcNix =
  ThunkSpec name $
    Map.fromList
      [ ("default.nix", ThunkFileSpec_FileMatches defaultNixViaSrc)
      , ("thunk.nix", ThunkFileSpec_FileMatches srcNix)
      , (jsonFileName, ThunkFileSpec_Ptr parser)
      , (attrCacheFileName, ThunkFileSpec_AttrCache)
      , (normalise $ unpackedDirName </> ".git", ThunkFileSpec_CheckoutIndicator)
      ]
  where
    defaultNixViaSrc =
      """
      # DO NOT HAND-EDIT THIS FILE
      import (import ./thunk.nix)
      """

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
    let getModificationTimeMaybe = fmap rightToMaybe . try @IOError . getModificationTime
        thunkFileNames = L.delete attrCacheFileName $ Map.keys $ _thunkSpec_files thunkSpec
    maximumMaybe . catMaybes <$> traverse (getModificationTimeMaybe . (thunkDir </>)) thunkFileNames

  let cachesAttrs = any isAttrCache $ _thunkSpec_files thunkSpec
      isAttrCache = \case
        ThunkFileSpec_AttrCache -> True
        _ -> False
  for (guard cachesAttrs) $ \() -> do
    cachePath <- liftIO $ (</> attr <.> "out") <$> attrCacheDir thunkDir
    let cacheErrHandler e
          | isDoesNotExistError e = pure Nothing -- expected from a cache miss
          | otherwise = Nothing <$ putLog Error (T.pack $ displayException e)
    cacheHit <- handle cacheErrHandler $ do
      cacheTime <- liftIO $ posixSecondsToUTCTime . realToFrac . modificationTime <$> getSymbolicLinkStatus cachePath
      pure $
        -- This code cannot read a modification time for any thunk file, so it
        -- cannot show that the cache is current. It treats that case as a miss,
        -- and it rebuilds.
        if maybe False (<= cacheTime) latestChange
          then Just cachePath
          else Nothing
    case cacheHit of
      Just c -> pure c
      Nothing -> do
        putLog Warning $ T.pack $ mconcat [thunkDir, ": ", attr, " not cached, building ..."]
        liftIO $ createDirectoryIfMissing True (takeDirectory cachePath)
        let buildTarget =
              Target
                { _target_path = Just thunkDir
                , _target_attr = Just attr
                , _target_expr = Nothing
                }
            buildCfg =
              def
                & nixBuildConfig_outLink .~ OutLink_IndirectRoot cachePath
                & nixCmdConfig_target .~ buildTarget
        cachePath <$ nixCmd (NixCmd_Build buildCfg)

-- | The location of the results of 'nixBuildThunkAttrWithCache'.
--
-- This location sits outside the thunk directory, and 'attrCacheFileName' still
-- names a directory inside the thunk. A consumer now also uses a packed thunk
-- as a @path:@ flake input, so Nix copies everything inside the thunk into the
-- store. The narHash that a consumer's @flake.lock@ records covers all of it. A
-- cache inside the thunk would therefore change the thunk when somebody built
-- one of its attributes. Two developers would then compute different hashes for
-- the same commit. The links are indirect GC roots, so they keep their targets
-- alive from any location.
attrCacheDir :: FilePath -> IO FilePath
attrCacheDir thunkDir = do
  cacheRoot <- getXdgDirectory XdgCache "nix-thunk"
  key <- attrCacheKey <$> canonicalizePath thunkDir
  pure $ cacheRoot </> "attrs" </> key

-- | A thunk's location, in a form that this code can use as a directory name.
attrCacheKey :: FilePath -> FilePath
attrCacheKey = show . hashWith SHA1 . encodeUtf8 . T.pack

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
nixBuildAttrWithCache exprPath attr =
  readThunk exprPath >>= \case
    -- Only packed thunks are cached. In particular, checkouts are not.
    Right (ThunkData_Packed spec _) ->
      maybe build pure =<< nixBuildThunkAttrWithCache spec exprPath attr
    _ -> build
  where
    build = nixCmd $ NixCmd_Build buildCfg
    buildCfg =
      def
        & nixBuildConfig_outLink .~ OutLink_None
        & nixCmdConfig_target .~ buildTarget
    buildTarget =
      Target
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
    copyThunkToTmp tmpDir thunkDir =
      readThunk thunkDir >>= \case
        Left err -> failReadThunkErrorWhile "during an update" err
        Right ThunkData_Packed {} -> do
          let tmpThunk = tmpDir </> "thunk"
          callProcessAndLogOutput (Notice, Error) $
            Cli.proc cp ["-r", "-T", thunkDir, tmpThunk]
          return tmpThunk
        Right _ -> failWith "Thunk is not packed"
    updateThunkFromTmp p' = do
      _ <- packThunk' True (ThunkPackConfig False (ThunkConfig Nothing Nothing False)) p'
      callProcessAndLogOutput (Notice, Error) $
        Cli.proc cp ["-r", "-T", p', p]

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
unpackThunk' noTrail thunkDir =
  checkThunkDirectory thunkDir *> readThunk thunkDir >>= \case
    Left err -> failReadThunkErrorWhile "while unpacking" err
    -- TODO: Overwrite option that rechecks out thunk; force option to do so even if working directory is dirty
    Right ThunkData_Checkout -> failWith [i|Thunk at ${thunkDir} is already unpacked|]
    Right (ThunkData_Packed spec tptr) -> do
      let (thunkParent, thunkName) = splitFileName thunkDir
      withTempDirectory thunkParent thunkName $ \tmpThunk -> do
        -- This code keeps the format that the thunk already has, and it does
        -- not use the newest format. A thunk from @--no-flake@ has no flake
        -- interface, and an unpack must not add one.
        let gitSrc = thunkSourceToGitSource $ _thunkPtr_source tptr
        withSpinner'
          ("Fetching thunk " <> T.pack thunkName)
          (finalMsg noTrail $ const $ "Fetched thunk " <> T.pack thunkName)
          $ do
            let unpackedPath = tmpThunk </> unpackedDirName
            gitCloneForThunkUnpack gitSrc (_thunkRev_commit $ _thunkPtr_rev tptr) unpackedPath

            when (specHasFlakeFiles spec) $ preserveFlakeInterface unpackedPath

            let normalizeMore = dropTrailingPathSeparator . normalise
            -- This code writes the metadata only when the checkout is not in
            -- place.
            when (normalizeMore unpackedPath /= normalizeMore tmpThunk) $
              createThunkWithSpec tmpThunk spec Nothing

            liftIO $ do
              removePathForcibly thunkDir
              renameDirectory tmpThunk thunkDir

-- | Takes the generated flake interface out of a checkout for the length of an
-- action, and restores the interface when the action fails.
--
-- A pack must remove the generated files before it inspects the checkout,
-- because the cleanliness check counts ignored files as unsaved work. A pack
-- can then reject the checkout, and it must return the checkout to the
-- developer unchanged. A pack that refused to act would otherwise break every
-- sibling flake that has the thunk as a @path:@ input.
withoutPreservedFlakeInterface :: MonadNixThunk m => FilePath -> m a -> m a
withoutPreservedFlakeInterface checkout act = do
  discarded <- discardPreservedFlakeInterface checkout
  let restore = when discarded $ preserveFlakeInterface checkout
  (act `onException` restore) `catchError` \e -> restore *> throwError e

-- | Undoes 'preserveFlakeInterface', and reports whether it had anything to
-- undo.
--
-- This code removes both files or neither file, and it acts only when the
-- @flake.nix@ is still the generated one. Content alone cannot identify the
-- @flake.lock@, because an empty lock matches byte for byte what Nix writes for
-- any flake without inputs. A content check would therefore delete a lock that
-- a repository tracks as its own. The user can write a @flake.nix@ by hand
-- after the unpack. This code then leaves both files in place, and the
-- cleanliness check reports them.
discardPreservedFlakeInterface :: MonadNixThunk m => FilePath -> m Bool
discardPreservedFlakeInterface checkout = do
  ours <- liftIO $ hasContent (flakeNixPath checkout) Flake.unpackedSourceFlakeNix
  when ours $ do
    for_ generatedFlakeFiles $ \(name, _) -> do
      putLog Debug $ "Removing generated " <> T.pack (checkout </> name)
      liftIO $ removePathForcibly $ checkout </> name
    excludeFile <- gitExcludeFile checkout
    excluded <- liftIO $ readFileMaybe excludeFile
    for_ excluded $ liftIO . writeUtf8File excludeFile . T.replace flakeExcludeBlock ""
  pure ours

-- | A packed thunk of a repository that is not itself a flake still exposes the
-- fetched source as a flake output. An unpack replaces the thunk with a bare
-- checkout. A consumer that uses the thunk as a flake input would then have
-- nothing to resolve. So this code writes the same interface into the checkout.
--
-- This code writes nothing when the repository already holds a @flake.nix@ or a
-- @flake.lock@. Either file shows that the repository owns its flake files.
-- This code must not overwrite a tracked file, because that file holds work
-- that exists nowhere else.
--
-- This code hides the generated files through git's own @info\/exclude@, and it
-- does not use a tracked ignore file. So the checkout stays clean, and nobody
-- can commit the generated files by accident.
preserveFlakeInterface :: MonadNixThunk m => FilePath -> m ()
preserveFlakeInterface checkout = do
  hasOwnFlake <- liftIO $ or <$> traverse (doesFileExist . (checkout </>) . fst) generatedFlakeFiles
  unless hasOwnFlake $ do
    putLog Debug $ "Writing flake files into checkout " <> T.pack checkout
    excludeFile <- gitExcludeFile checkout
    liftIO $ do
      for_ generatedFlakeFiles $ \(name, content) -> writeUtf8File (checkout </> name) content
      createDirectoryIfMissing True $ takeDirectory excludeFile
      excluded <- readFileMaybe excludeFile
      unless (flakeExcludeBlock `T.isInfixOf` fold excluded) $
        appendUtf8File excludeFile flakeExcludeBlock

-- | The flake interface that this code writes into an unpacked checkout, and
-- removes again.
generatedFlakeFiles :: [(FilePath, Text)]
generatedFlakeFiles =
  [ (flakeNixFileName, Flake.unpackedSourceFlakeNix)
  , (flakeLockFileName, Flake.emptyFlakeLock)
  ]

-- | This block goes into git's @info\/exclude@ to hide the generated files. A
-- pack matches the whole block, so it can remove the block again.
flakeExcludeBlock :: Text
flakeExcludeBlock =
  T.unlines $
    [ ""
    , "# Written by nix-thunk; removed when the thunk is packed."
    ]
      <> ["/" <> T.pack name | (name, _) <- generatedFlakeFiles]

-- | The file where git reads a repository's own ignore patterns.
--
-- This code asks git for the path, and it does not assemble the path from
-- @.git\/info\/exclude@. In a worktree, @.git@ is a file, and the real
-- directory sits elsewhere. Git shares this file between a repository and its
-- worktrees, so a worktree of a thunk also hides these names in the developer's
-- own checkout. The repository does not use these names. This code writes the
-- files only when the repository has neither of them. A pack of the thunk
-- removes the block again.
gitExcludeFile :: MonadNixThunk m => FilePath -> m FilePath
gitExcludeFile checkout = do
  out <- T.unpack . T.strip <$> readGitProcess checkout ["rev-parse", "--git-common-dir"]
  let gitDir = if isAbsolute out then out else checkout </> out
  pure $ gitDir </> "info" </> "exclude"

readFileMaybe :: FilePath -> IO (Maybe Text)
readFileMaybe path = rightToMaybe <$> try @IOError (T.readFile path)

-- | 'True' when a file is present and holds the given text. This function
-- ignores the whitespace around the text.
hasContent :: FilePath -> Text -> IO Bool
hasContent path expected = (== Just (T.strip expected)) . fmap T.strip <$> readFileMaybe path

gitCloneForThunkUnpack
  :: MonadNixThunk m
  => GitSource
  -- ^ Git source to use
  -> Ref hash
  -- ^ Commit hash to reset to
  -> FilePath
  -- ^ Directory to clone into
  -> m ()
gitCloneForThunkUnpack gitSrc commit dir = do
  _ <-
    readGitProcess dir $
      ["clone"]
        <> ["--recursive" | _gitSource_fetchSubmodules gitSrc]
        <> [T.unpack $ gitUriToText $ _gitSource_url gitSrc]
        <> do
          branch <- maybeToList $ _gitSource_branch gitSrc
          ["--branch", T.unpack $ untagName branch]
  _ <- readGitProcess dir ["reset", "--hard", refToHexString commit]
  when (_gitSource_fetchSubmodules gitSrc) $
    void $
      readGitProcess dir ["submodule", "update", "--recursive", "--init"]

createWorktree :: MonadNixThunk m => FilePath -> FilePath -> CreateWorktreeConfig -> m ()
createWorktree thunkDir gitDir config =
  checkThunkDirectory thunkDir *> readThunk thunkDir >>= \case
    Left err -> failReadThunkErrorWhile "while creating worktree" err
    Right ThunkData_Checkout -> failWith [i|Thunk at ${thunkDir} is already unpacked|]
    Right (ThunkData_Packed _ tptr) -> do
      ensureGitRevExist gitDir tptr

      let (thunkParent, thunkName) = splitFileName thunkDir
      withTempDirectory thunkParent thunkName $ \tmpThunk -> do
        withSpinner'
          ("Creating worktree for " <> T.pack thunkName)
          (Just (const $ "Created worktree for " <> T.pack thunkName))
          $ do
            currentDir <- liftIO getCurrentDirectory
            let worktreePath = currentDir </> tmpThunk </> unpackedDirName
                thunkFullPath = currentDir </> thunkDir </> unpackedDirName

                -- Create a new branch with the user specified name if provided
                -- else fallback to the branch specified in thunk
                -- If a local branch already exists in gitDir, the worktree creation will fail
                -- In which case the user should specify an alternate branch or use "-d"
                mBranchName = case _createWorktreeConfig_branch config of
                  Just b -> Just b
                  _ -> T.unpack . untagName <$> _gitSource_branch (thunkSourceToGitSource $ _thunkPtr_source tptr)

            _ <-
              readGitProcess gitDir $
                [ "worktree"
                , "add"
                , worktreePath
                , refToHexString (_thunkRev_commit $ _thunkPtr_rev tptr)
                ]
                  <> ( if _createWorktreeConfig_detach config
                         then ["-d"]
                         else maybe [] (\b -> ["-b", b]) mBranchName
                     )

            liftIO $ removePathForcibly thunkDir

            _ <-
              readGitProcess
                gitDir
                [ "worktree"
                , "move"
                , normalise worktreePath
                , normalise thunkFullPath
                ]

            -- A worktree replaces the thunk in the same way that an unpacked
            -- checkout does, so it needs the same flake interface. A pack
            -- discards that interface in both cases.
            when (specHasFlakeFiles $ thunkPtrToSpec tptr) $
              preserveFlakeInterface $
                normalise thunkFullPath

-- | Ensures that the git repo contains the revision specified in the ThunkPtr
-- by doing fetch from remote if necessary.
ensureGitRevExist :: MonadNixThunk m => FilePath -> ThunkPtr -> m ()
ensureGitRevExist gitDir tptr = do
  isdir <- liftIO $ doesDirectoryExist gitDir
  -- check .git
  unless isdir $ failWith $ "Git directory does not exist: " <> T.pack gitDir

  (exitCode, _, _) <-
    readCreateProcessWithExitCode $
      gitProc
        gitDir
        [ "reflog"
        , "exists"
        , refToHexString (_thunkRev_commit $ _thunkPtr_rev tptr)
        ]

  when (exitCode /= ExitSuccess) $ do
    void $
      readGitProcess
        gitDir
        [ "fetch"
        , T.unpack $ gitUriToText (_gitSource_url $ thunkSourceToGitSource $ _thunkPtr_source tptr)
        , refToHexString (_thunkRev_commit $ _thunkPtr_rev tptr)
        ]

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
    envfix =
      Map.fromList
        [ ("GIT_CONFIG_NOSYSTEM", "yes")
        , -- Git documentation says GIT_CONFIG_GLOBAL=/dev/null should
          -- prevent it from reading the global config file but that's a
          -- lie, actually.
          ("HOME", "/dev/null")
        , ("XDG_CONFIG_HOME", "/dev/null")
        ]

-- TODO: add a rollback mode to pack to the original thunk
packThunk :: MonadNixThunk m => ThunkPackConfig -> FilePath -> m ThunkPtr
packThunk = packThunk' False

packThunk' :: MonadNixThunk m => Bool -> ThunkPackConfig -> FilePath -> m ThunkPtr
packThunk' noTrail (ThunkPackConfig force thunkConfig) thunkDir =
  checkThunkDirectory thunkDir *> readThunk thunkDir >>= \case
    Right ThunkData_Packed {} -> failWith [i|Thunk at ${thunkDir} is is already packed|]
    _ -> withSpinner'
      ("Packing thunk " <> T.pack thunkDir)
      (finalMsg noTrail $ const $ "Packed thunk " <> T.pack thunkDir)
      $ do
        let checkClean = if force then CheckClean_NoCheck else CheckClean_FullCheck
        -- This code assembles the packed thunk beside the checkout, and it
        -- replaces the checkout only after the thunk is complete. The flake
        -- files need the network, and a failure there must not leave the
        -- developer without a checkout and without a readable thunk. So this
        -- code restores the checkout's flake interface when any step fails.
        let (thunkParent, thunkName) = splitFileName thunkDir
        withTempDirectory thunkParent thunkName $ \tmpThunk -> do
          let staged = tmpThunk </> "packed"
          (thunkPtr, isWorktree) <- withoutPreservedFlakeInterface thunkDir $ do
            packed <-
              first (modifyThunkPtrByConfig thunkConfig)
                <$> getThunkPtr checkClean thunkDir (_thunkConfig_private thunkConfig)
            packed <$ createThunkWithSpec staged (thunkSpecFor thunkConfig $ fst packed) (Just $ fst packed)
          if isWorktree
            then void $ do
              -- Remove the branch locally. Then remove the worktree.
              case _gitSource_branch $ thunkSourceToGitSource $ _thunkPtr_source thunkPtr of
                Just branch -> do
                  void $ readGitProcess thunkDir ["switch", "--detach"]
                  void $ readGitProcess thunkDir ["branch", "-d", T.unpack $ untagName branch]
                Nothing -> pure () -- Should never happen
              readGitProcess thunkDir ["worktree", "remove", "."]
            else liftIO $ removePathForcibly thunkDir
          liftIO $ renameDirectory staged thunkDir
          pure thunkPtr

modifyThunkPtrByConfig :: ThunkConfig -> ThunkPtr -> ThunkPtr
modifyThunkPtrByConfig config ptr =
  ptr {_thunkPtr_source = withSubmodules $ withPrivate $ _thunkPtr_source ptr}
  where
    withPrivate src = case _thunkConfig_private config of
      Nothing -> src
      Just markPrivate -> case src of
        ThunkSource_Git s -> ThunkSource_Git $ s {_gitSource_private = markPrivate}
        ThunkSource_GitHub s -> ThunkSource_GitHub $ s {_gitHubSource_private = markPrivate}
    withSubmodules src = maybe src (`setThunkSourceSubmodules` src) $ _thunkConfig_submodules config

data CheckClean
  = -- | Check that the repo is clean, including .gitignored files
    CheckClean_FullCheck
  | -- | Check that the repo is clean, not including .gitignored files
    CheckClean_NotIgnored
  | -- | Don't check that the repo is clean
    CheckClean_NoCheck

getThunkPtr :: forall m. MonadNixThunk m => CheckClean -> FilePath -> Maybe Bool -> m (ThunkPtr, Bool)
getThunkPtr gitCheckClean dir mPrivate = do
  let repoLocations =
        nubOrd $
          map
            (first normalise)
            [(".git", "."), (unpackedDirName </> ".git", unpackedDirName)]
  repoLocation' <- liftIO $ flip findM repoLocations $ doesDirectoryExist . (dir </>) . fst
  (thunkDir, isWorktree) <- case repoLocation' of
    Nothing -> do
      ff <- liftIO $ flip findM repoLocations $ doesFileExist . (dir </>) . fst
      case ff of
        Nothing -> failWith [i|Can't find an unpacked thunk in ${dir}|]
        Just (gitPath, path) -> do
          putLog Informational "Couldn't find .git dir, looking for a worktree instead"
          fileContents <- liftIO $ T.readFile (dir </> gitPath)
          unless (T.isPrefixOf "gitdir: " fileContents) $ failWith [i|Can't find an unpacked thunk or worktree in ${dir}|]
          pure (normalise $ dir </> path, True)
    Just (_, path) -> pure (normalise $ dir </> path, False)

  let (checkClean, checkIgnored) = case gitCheckClean of
        CheckClean_FullCheck -> (True, True)
        CheckClean_NotIgnored -> (True, False)
        CheckClean_NoCheck -> (False, False)
  when checkClean $
    ensureCleanGitRepo
      thunkDir
      checkIgnored
      "thunk pack: thunk checkout contains unsaved modifications"

  -- Check whether there are any stashes
  when (checkClean && not isWorktree) $ do
    stashOutput <- readGitProcess thunkDir ["stash", "list"]
    unless (T.null stashOutput) $
      failWith $
        T.unlines $
          [ "thunk pack: thunk checkout has stashes"
          , "git stash list:"
          ]
            <> T.lines stashOutput

  -- Get current branch
  (mCurrentBranch, mCurrentCommit) <- do
    b <- listToMaybe . T.lines <$> readGitProcess thunkDir ["rev-parse", "--abbrev-ref", "HEAD"]
    c <- listToMaybe . T.lines <$> readGitProcess thunkDir ["rev-parse", "HEAD"]
    case b of
      (Just "HEAD") ->
        failWith
          """
          thunk pack: You are in 'detached HEAD' state.
          If you want to pack at the current ref then please create a new branch with 'git checkout -b <new-branch-name>' and push this upstream.
          """
      _ -> return (b, c)

  let refs =
        if isWorktree
          -- Get information on current branch only
          then "refs/heads/" <> maybe "" T.unpack mCurrentBranch
          -- Get information on all branches and their (optional) designated
          -- upstream correspondents
          else "refs/heads/"
  headDump :: [Text] <-
    T.lines
      <$> readGitProcess
        thunkDir
        [ "for-each-ref"
        , "--format=%(refname:short) %(upstream:short) %(upstream:remotename)"
        , refs
        ]

  (headInfo :: Map Text (Maybe (Text, Text))) <-
    fmap Map.fromList $ forM headDump $ \line -> do
      (branch : restOfLine) <- pure $ T.words line
      mUpstream <- case restOfLine of
        [] -> pure Nothing
        [u, r] -> pure $ Just (u, r)
        (_ : _) -> failWith "git for-each-ref invalid output"
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
    when (not $ L.null untrackedBranches) $
      failWith $
        T.unlines $
          [ "thunk pack: Certain branches in the thunk have no upstream branch \
            \set. This means we don't know to check whether all your work is \
            \saved. The offending branches are:"
          , ""
          , T.unwords untrackedBranches
          , ""
          , "To fix this, you probably want to do:"
          , ""
          ]
            <> (("git push -u origin " <>) <$> untrackedBranches)
            <> [ ""
               , "These will push the branches to the default remote under the same \
                 \name, and (thanks to the `-u`) remember that choice so you don't \
                 \get this error again."
               ]

    -- loosely by https://stackoverflow.com/questions/7773939/show-git-ahead-and-behind-info-for-all-branches-including-remotes
    stats <- ifor headUpstream $ \branch (upstream, _remote) -> do
      (stat :: [Text]) <-
        T.lines
          <$> readGitProcess
            thunkDir
            [ "rev-list"
            , "--left-right"
            , T.unpack branch <> "..." <> T.unpack upstream
            ]
      let ahead = length $ [() | Just ('<', _) <- T.uncons <$> stat]
          behind = length $ [() | Just ('>', _) <- T.uncons <$> stat]
      pure (upstream, (ahead, behind))

    -- Those branches which have commits ahead of, i.e. not on, the upstream
    -- branch. Purely being behind is fine.
    let nonGood = Map.filter ((/= 0) . fst . snd) stats

    when (not $ Map.null nonGood) $
      failWith $
        T.unlines $
          mconcat
            [
              [ "thunk pack: Certain branches in the thunk have commits not yet pushed upstream:"
              , ""
              ]
            , [ "  " <> branch <> " ahead: " <> T.pack (show ahead) <> " behind: " <> T.pack (show behind) <> " remote branch " <> upstream
              | (branch, (upstream, (ahead, behind))) <- Map.toList nonGood
              ]
            ,
              [ ""
              , "Please push these upstream and try again. (Or just fetch, if they are somehow \
                \pushed but this repo's remote tracking branches don't know it.)"
              ]
            ]

  when checkClean $ do
    -- We assume it's safe to pack the thunk at this point
    putLog Informational "All changes safe in git remotes. OK to pack thunk."

  let remote = maybe "origin" snd $ flip Map.lookup headUpstream =<< mCurrentBranch

  [remoteUri'] <-
    T.lines
      <$> readGitProcess
        thunkDir
        [ "config"
        , "--get"
        , "remote." <> T.unpack remote <> ".url"
        ]

  remoteUri <- case parseGitUri remoteUri' of
    Nothing -> failWith $ "Could not identify git remote: " <> remoteUri'
    Just uri -> pure uri
  (,isWorktree) <$> uriThunkPtr remoteUri mPrivate Nothing mCurrentBranch mCurrentCommit

-- | Get the latest revision available from the given source
getLatestRev :: MonadNixThunk m => ThunkSource -> m ThunkRev
getLatestRev os = do
  let gitS = thunkSourceToGitSource os
  (_, commit) <- gitGetCommitBranch (_gitSource_url gitS) (untagName <$> _gitSource_branch gitS)
  getThunkRev os commit

-- | Convert a URI to a thunk
--
-- If the URL is a github URL, we try to just download an archive for
-- performance. If that doesn't work (e.g. authentication issue), we fall back
-- on just doing things the normal way for git repos in general, and save it as
-- a regular git thunk.
-- | The submodule setting is applied before the revision is resolved, because
-- the hash of a source that carries submodules is not the hash of one that
-- does not.
uriThunkPtr :: MonadNixThunk m => GitUri -> Maybe Bool -> Maybe Bool -> Maybe Text -> Maybe Text -> m ThunkPtr
uriThunkPtr uri mPrivate mSubmodules mbranch mcommit = do
  commit <- case mcommit of
    Nothing -> snd <$> gitGetCommitBranch uri mbranch
    (Just c) -> return c
  (src, rev) <-
    (maybe id setThunkSourceSubmodules mSubmodules <$> uriToThunkSource uri mPrivate mbranch) >>= \case
      -- A source that needs submodules is hashed through the git fetcher. The
      -- archive githubThunkRev reads carries none of them.
      ThunkSource_GitHub s | _gitHubSource_fetchSubmodules s -> do
        let s' = forgetGithub (_gitHubSource_private s) s
        (,) (ThunkSource_GitHub s) <$> gitThunkRev s' commit
      ThunkSource_GitHub s -> do
        rev <- runExceptT $ githubThunkRev s commit
        case rev of
          Right r -> pure (ThunkSource_GitHub s, r)
          Left e -> do
            putLog
              Warning
              "\
              \Failed to fetch archive from GitHub. This is probably a private repo. \
              \Falling back on normal fetchgit. Original failure:"
            putLog Warning $ prettyNixThunkError e
            let s' = forgetGithub True s
            (,) (ThunkSource_Git s') <$> gitThunkRev s' commit
      ThunkSource_Git s -> (,) (ThunkSource_Git s) <$> gitThunkRev s commit
  pure $
    ThunkPtr
      { _thunkPtr_rev = rev
      , _thunkPtr_source = src
      }

-- | Convert a 'ThunkCreateSource` to a 'ThunkPtr'.
thunkCreateSourcePtr
  :: MonadNixThunk m
  => ThunkCreateSource
  -- ^ Where is the repository?
  -> Maybe Bool
  -- ^ Is it private?
  -> Maybe Bool
  -- ^ Does it need its submodules?
  -> Maybe Text
  -- ^ Shall we fetch a specific branch?
  -> Maybe Text
  -- ^ Shall we check out a specific commit?
  -> m ThunkPtr
thunkCreateSourcePtr source mPriv mSubmodules mBranch mCommit = do
  uri <- case source of
    ThunkCreateSource_Absolute uri -> pure uri
    ThunkCreateSource_Relative dir -> do
      isdir <- liftIO $ doesDirectoryExist dir
      if isdir
        then do
          absolute <- liftIO $ makeAbsolute dir
          pure $
            fromMaybe (error "parsing a file:// URI should never fail") $
              parseGitUri ("file://" <> T.pack absolute)
        else failWith $ "Path does not refer to a directory: " <> T.pack dir
  uriThunkPtr uri mPriv mSubmodules mBranch mCommit

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
      "ssh" ->
        uriAuth
          == URI.Authority
            { URI.authUserInfo = Just $ URI.UserInfo (fromRight' $ URI.mkUsername "git") Nothing
            , URI.authHost = fromRight' $ URI.mkHost "github.com"
            , URI.authPort = Nothing
            }
      s ->
        s `L.elem` ["git", "https", "http"] -- "http:" just redirects to "https:"
          && URI.unRText (URI.authHost uriAuth) == "github.com"
  , Just (_, owner :| [repoish]) <- URI.uriPath u =
      \mbranch -> do
        isPrivate <- getIsPrivate
        let repoish' = URI.unRText repoish
            src =
              GitHubSource
                { _gitHubSource_owner = N $ URI.unRText owner
                , _gitHubSource_repo = N $ fromMaybe repoish' $ T.stripSuffix ".git" repoish'
                , _gitHubSource_branch = N <$> mbranch
                , _gitHubSource_fetchSubmodules = False
                , _gitHubSource_private = isPrivate
                }
        pure $ ThunkSource_GitHub src
  | otherwise = \mbranch -> do
      isPrivate <- getIsPrivate
      let src =
            GitSource
              { _gitSource_url = GitUri u
              , _gitSource_branch = N <$> mbranch
              , _gitSource_fetchSubmodules = False -- TODO: How do we determine if this should be true?
              , _gitSource_private = isPrivate
              }
      pure $ ThunkSource_Git src
  where
    getIsPrivate = maybe (guessGitRepoIsPrivate $ GitUri u) pure mPrivate

guessGitRepoIsPrivate :: MonadNixThunk m => GitUri -> m Bool
guessGitRepoIsPrivate uri = flip fix urisToTry $ \loop -> \case
  [] -> pure True
  uriAttempt : xs -> do
    let lsRemote =
          gitProcNoRepo
            [ "ls-remote"
            , "--quiet"
            , "--exit-code"
            , "--symref"
            , T.unpack $ gitUriToText uriAttempt
            ]
    result <- readCreateProcessWithExitCode $ isolateGitProc lsRemote
    case result of
      (ExitSuccess, _, _) -> pure False -- Must be a public repo
      _ -> loop xs
  where
    urisToTry =
      nubOrd $
        -- Include the original URI if it isn't using SSH because SSH will certainly fail.
        [uri | fmap URI.unRText (URI.uriScheme (unGitUri uri)) /= Just "ssh"]
          <> [changeScheme "https" uri, changeScheme "http" uri]
    changeScheme scheme (GitUri u) =
      GitUri $
        u
          { URI.uriScheme = URI.mkScheme scheme
          , URI.uriAuthority = (\x -> x {URI.authUserInfo = Nothing}) <$> URI.uriAuthority u
          }

getThunkRev
  :: forall m
   . MonadNixThunk m
  => ThunkSource
  -> Text
  -> m ThunkRev
getThunkRev os commit = case os of
  -- The archive that githubThunkRev hashes carries no submodules, so a
  -- source that needs them is hashed through the git fetcher instead.
  ThunkSource_GitHub s
    | _gitHubSource_fetchSubmodules s ->
        gitThunkRev (forgetGithub (_gitHubSource_private s) s) commit
    | otherwise -> githubThunkRev s commit
  ThunkSource_Git s -> gitThunkRev s commit

-- Funny signature indicates no effects depend on the optional branch name.
githubThunkRev
  :: forall m
   . MonadNixThunk m
  => GitHubSource
  -> Text
  -> m ThunkRev
githubThunkRev s commit = do
  owner <- forcePP $ _gitHubSource_owner s
  repo <- forcePP $ _gitHubSource_repo s
  revTarball <- URI.mkPathPiece $ commit <> ".tar.gz"
  let authority =
        URI.Authority
          { URI.authUserInfo = Nothing
          , URI.authHost = fromRight' $ URI.mkHost "github.com"
          , URI.authPort = Nothing
          }
      path = owner :| [repo, fromRight' $ URI.mkPathPiece "archive", revTarball]
      uri =
        URI.URI
          { URI.uriScheme = Just $ fromRight' $ URI.mkScheme "https"
          , URI.uriAuthority = Right authority
          , URI.uriPath = Just (False, path)
          , URI.uriQuery = []
          , URI.uriFragment = Nothing
          }
      archiveUri = GitUri uri
  hash <- getNixSha256ForUriUnpacked archiveUri
  putLog Debug $ "Nix sha256 is " <> hash
  return $
    ThunkRev
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
    failWith $
      "obelisk currently only supports "
        <> T.intercalate ", " protocols
        <> " protocols for plain Git remotes"
  hash <- nixPrefetchGit u commit $ _gitSource_fetchSubmodules s
  putLog Informational $ "Nix sha256 is " <> hash
  pure $
    ThunkRev
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
  (_, bothMaps) <-
    gitLsRemote
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
  putLog Informational $
    "Latest commit in branch "
      <> branch
      <> " from remote repo "
      <> uriMsg
      <> " is "
      <> commit
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
  let (authAndHostname, colonAndPath) = T.break (== ':') uri
      properUri = "ssh://" <> authAndHostname <> "/" <> T.drop 1 colonAndPath
  -- Shorthand is valid iff a colon is present and it occurs before the first slash
  -- This check is used to disambiguate a filepath containing a colon from shorthand
  guard $
    isNothing (T.findIndex (== '/') authAndHostname)
      && not (T.null colonAndPath)
  URI.mkURI properUri

-- The following code has been adapted from the 'Data.Git.Ref',
-- which is apparently no longer maintained

-- | Represent a git reference (SHA1)
newtype Ref hash = Ref {unRef :: Digest hash}
  deriving stock (Eq, Ord)

-- | Invalid Reference exception raised when
-- using something that is not a ref as a ref.
newtype RefInvalid = RefInvalid {unRefInvalid :: ByteString}
  deriving stock (Data, Eq, Show)

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
