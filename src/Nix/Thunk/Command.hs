{-# LANGUAGE FlexibleContexts #-}
module Nix.Thunk.Command where

import Control.Monad.Catch (MonadMask)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Fail (MonadFail)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Log (MonadLog)
import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Nix.Thunk
import Cli.Extras (HasCliConfig, Output)
import Options.Applicative
import System.FilePath

thunkConfig :: Parser ThunkConfig
thunkConfig = ThunkConfig
  <$>
    (   flag' (Just True) (long "private" <> help "Mark thunks as pointing to a private repository")
    <|> flag' (Just False) (long "public" <> help "Mark thunks as pointing to a public repository")
    <|> pure Nothing
    )

thunkUpdateConfig :: Parser ThunkUpdateConfig
thunkUpdateConfig = ThunkUpdateConfig
  <$> optional (strOption (long "branch" <> metavar "BRANCH" <> help "Use the given branch when looking for the latest revision"))
  <*> thunkConfig

thunkPackConfig :: Parser ThunkPackConfig
thunkPackConfig = ThunkPackConfig
  <$> switch (long "force" <> short 'f' <> help "Force packing thunks even if there are branches not pushed upstream, uncommitted changes, stashes. This will cause changes that have not been pushed upstream to be lost; use with care.")
  <*> thunkConfig

data ThunkOption = ThunkOption
  { _thunkOption_thunks :: NonEmpty FilePath
  , _thunkOption_command :: ThunkCommand
  } deriving Show

data ThunkCommand
  = ThunkCommand_Update ThunkUpdateConfig
  | ThunkCommand_Unpack
  | ThunkCommand_Pack ThunkPackConfig
  deriving Show

thunkOption :: Parser ThunkOption
thunkOption = hsubparser $ mconcat
  [ command "update" $ info (thunkOptionWith $ ThunkCommand_Update <$> thunkUpdateConfig) $ progDesc "Update packed thunk to latest revision available on the tracked branch"
  , command "unpack" $ info (thunkOptionWith $ pure ThunkCommand_Unpack) $ progDesc "Unpack thunk into git checkout of revision it points to"
  , command "pack" $ info (thunkOptionWith $ ThunkCommand_Pack <$> thunkPackConfig) $ progDesc "Pack git checkout or unpacked thunk into thunk that points at the current branch's upstream"
  ]
  where
    thunkOptionWith f = ThunkOption
      <$> ((:|)
            <$> thunkDirArg (metavar "THUNKDIRS..." <> help "Paths to directories containing thunk data")
            <*> many (thunkDirArg mempty)
          )
      <*> f
    thunkDirArg opts = fmap (dropTrailingPathSeparator . normalise) $ strArgument $ action "directory" <> opts

runThunkOption
  :: ( MonadLog Output m
     , HasCliConfig m
     , MonadIO m
     , MonadMask m
     , MonadError NixThunkError m
     , MonadFail m
     )
  => ThunkOption -> m ()
runThunkOption to = case _thunkOption_command to of
  ThunkCommand_Update config -> for_ thunks (updateThunkToLatest config)
  ThunkCommand_Unpack -> for_ thunks unpackThunk
  ThunkCommand_Pack config -> for_ thunks (packThunk config)
  where thunks = _thunkOption_thunks to
