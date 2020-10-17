{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PackageImports #-}
import "nix-thunk" Nix.Thunk
import "nix-thunk" Nix.Thunk.Command
import Options.Applicative
import Cli.Extras
import qualified Data.Text.IO as T
import System.Environment
import System.Exit
import Data.Void

data Args = Args
  { _args_verbose :: Bool
  , _args_command :: ThunkCommand
  }

verbose :: Parser Bool
verbose = flag False True $ mconcat
  [ long "verbose"
  , short 'v'
  , help "Produce more detailed output"
  ]

args :: Parser Args
args = Args <$> verbose <*> thunkCommand

argsInfo :: ParserInfo Args
argsInfo = info (args <**> helper) $ mconcat
  [ fullDesc
  , progDesc "Manage source repositories using Nix"
  ]

parserPrefs :: ParserPrefs
parserPrefs = defaultPrefs
  { prefShowHelpOnEmpty = True
  }

main :: IO Void
main = do
  args <- getArgs
  args' <- handleParseResult $ execParserPure parserPrefs argsInfo args
  cliConf <- mkDefaultCliConfig args
  runCli cliConf (runThunkCommand (_args_command args')) >>= \case
    Right () -> exitWith ExitSuccess
    Left e -> do
      T.putStrLn $ prettyNixThunkError e
      exitWith $ ExitFailure 2
