{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
module Nix.Thunk.Command where

import Cli.Extras (HasCliConfig, Output)
import Control.Monad.Catch (MonadMask)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Fail (MonadFail)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Log (MonadLog)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Text as T
import Options.Applicative
import System.FilePath

import Nix.Thunk

thunkConfig :: Parser ThunkConfig
thunkConfig = ThunkConfig
  <$>
    (   flag' (Just True) (long "private" <> help "Mark thunks as pointing to a private repository")
    <|> flag' (Just False) (long "public" <> help "Mark thunks as pointing to a public repository")
    <|> pure Nothing
    )

thunkUpdateConfig :: Parser ThunkUpdateConfig
thunkUpdateConfig = ThunkUpdateConfig
  <$> optional (strOption (short 'b' <> long "branch" <> metavar "BRANCH" <> help "Use the given branch when looking for the latest revision"))
  <*> thunkConfig

thunkPackConfig :: Parser ThunkPackConfig
thunkPackConfig = ThunkPackConfig
  <$> switch (long "force" <> short 'f' <> help "Force packing thunks even if there are branches not pushed upstream, uncommitted changes, stashes. This will cause changes that have not been pushed upstream to be lost; use with care.")
  <*> thunkConfig

thunkCreateConfig :: Parser ThunkCreateConfig
thunkCreateConfig = ThunkCreateConfig
  <$> argument source (metavar "URI" <> help "Address of the target repository")
  <*> optional (strOption (short 'b' <> long "branch" <> metavar "BRANCH" <> help "Point the new thunk at the given branch"))
  <*> optional (option (refFromHexString <$> str) (long "rev" <> long "revision" <> metavar "REVISION" <> help "Point the new thunk at the given revision"))
  <*> thunkConfig
  <*> optional (strArgument (action "directory" <> metavar "DESTINATION" <> help "The name of a new directory to create for the thunk"))
  where
    source = (ThunkCreateSource_Absolute <$> maybeReader (parseGitUri . T.pack))
         <|> (ThunkCreateSource_Relative <$> str)

data ThunkCommand
  = ThunkCommand_Update ThunkUpdateConfig (NonEmpty FilePath)
  | ThunkCommand_Unpack (NonEmpty FilePath)
  | ThunkCommand_Worktree FilePath FilePath
  | ThunkCommand_Pack ThunkPackConfig (NonEmpty FilePath)
  | ThunkCommand_Create ThunkCreateConfig
  deriving Show

thunkDirList :: Parser (NonEmpty FilePath)
thunkDirList = (:|)
  <$> dirArg (metavar "THUNKDIRS..." <> help "Paths to directories containing thunk data")
  <*> many (dirArg mempty)

dirArg :: Mod ArgumentFields FilePath -> Parser FilePath
dirArg opts = fmap (dropTrailingPathSeparator . normalise) $ strArgument $ action "directory" <> opts

thunkCommand :: Parser ThunkCommand
thunkCommand = hsubparser $ mconcat
  [ command "update" $ info (ThunkCommand_Update <$> thunkUpdateConfig <*> thunkDirList) $ progDesc "Update packed thunk to latest revision available on the tracked branch"
  , command "unpack" $ info (ThunkCommand_Unpack <$> thunkDirList) $ progDesc "Unpack thunk into git checkout of revision it points to"
  , command "worktree" $ info (ThunkCommand_Worktree <$> dirArg mempty <*> dirArg mempty) $ progDesc "Create a git worktree of the thunk using the specified local git repo"
  , command "pack" $ info (ThunkCommand_Pack <$> thunkPackConfig <*> thunkDirList) $ progDesc "Pack git checkout or unpacked thunk into thunk that points at the current branch's upstream"
  , command "create" $ info (ThunkCommand_Create <$> thunkCreateConfig) $ progDesc "Create a packed thunk without cloning the repository first"
  ]

runThunkCommand
  :: ( MonadLog Output m
     , HasCliConfig NixThunkError m
     , MonadIO m
     , MonadMask m
     , MonadError NixThunkError m
     , MonadFail m
     )
  => ThunkCommand -> m ()
runThunkCommand = \case
  ThunkCommand_Update config dirs -> mapM_ (updateThunkToLatest config) dirs
  ThunkCommand_Unpack dirs -> mapM_ unpackThunk dirs
  ThunkCommand_Worktree thunkDir gitDir -> createWorktree thunkDir gitDir
  ThunkCommand_Pack config dirs -> mapM_ (packThunk config) dirs
  ThunkCommand_Create config -> createThunk' config
