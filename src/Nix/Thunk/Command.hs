{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
module Nix.Thunk.Command where

import Control.Monad.Catch (MonadMask)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Fail (MonadFail)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Log (MonadLog)
import Data.List.NonEmpty (NonEmpty (..))
import Nix.Thunk
import Cli.Extras (HasCliConfig, Output)
import Options.Applicative
import System.FilePath
import Data.Git.Ref
import qualified Data.Text as T

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
  <$> argument (maybeReader (parseGitUri . T.pack)) (metavar "URI" <> help "Address of the target repository")
  <*> optional (strOption (short 'b' <> long "branch" <> metavar "BRANCH" <> help "Point the new thunk at the given branch"))
  <*> optional (option (fromHexString <$> auto) (long "rev" <> long "revision" <> metavar "REVISION" <> help "Point the new thunk at the given revision"))
  <*> thunkConfig
  <*> optional (strArgument (action "directory" <> metavar "DESTINATION" <> help "The name of a new directory to create for the thunk"))

data ThunkCommand
  = ThunkCommand_Update ThunkUpdateConfig (NonEmpty FilePath)
  | ThunkCommand_Unpack (NonEmpty FilePath)
  | ThunkCommand_Pack ThunkPackConfig (NonEmpty FilePath)
  | ThunkCommand_Create ThunkCreateConfig
  deriving Show

thunkDirList :: Parser (NonEmpty FilePath)
thunkDirList = (:|)
  <$> thunkDirArg (metavar "THUNKDIRS..." <> help "Paths to directories containing thunk data")
  <*> many (thunkDirArg mempty)
  where
    thunkDirArg opts = fmap (dropTrailingPathSeparator . normalise) $ strArgument $ action "directory" <> opts

thunkCommand :: Parser ThunkCommand
thunkCommand = hsubparser $ mconcat
  [ command "update" $ info (ThunkCommand_Update <$> thunkUpdateConfig <*> thunkDirList) $ progDesc "Update packed thunk to latest revision available on the tracked branch"
  , command "unpack" $ info (ThunkCommand_Unpack <$> thunkDirList) $ progDesc "Unpack thunk into git checkout of revision it points to"
  , command "pack" $ info (ThunkCommand_Pack <$> thunkPackConfig <*> thunkDirList) $ progDesc "Pack git checkout or unpacked thunk into thunk that points at the current branch's upstream"
  , command "create" $ info (ThunkCommand_Create <$> thunkCreateConfig) $ progDesc "Create a packed thunk without cloning the repository first"
  ]

runThunkCommand
  :: ( MonadLog Output m
     , HasCliConfig m
     , MonadIO m
     , MonadMask m
     , MonadError NixThunkError m
     , MonadFail m
     )
  => ThunkCommand -> m ()
runThunkCommand = \case
  ThunkCommand_Update config dirs -> mapM_ (updateThunkToLatest config) dirs
  ThunkCommand_Unpack dirs -> mapM_ unpackThunk dirs
  ThunkCommand_Pack config dirs -> mapM_ (packThunk config) dirs
  ThunkCommand_Create config -> createThunk' config
