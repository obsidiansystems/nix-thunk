{-# LANGUAGE PackageImports #-}
import "nix-thunk" Nix.Thunk
import "nix-thunk" Nix.Thunk.Command
import Options.Applicative
import Cli.Extras
import Data.List (isInfixOf)
import System.Environment
import System.Exit
import System.IO (hIsTerminalDevice, stdout)
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
  rawArgs <- getArgs
  args' <- handleParseResult $ execParserPure parserPrefs argsInfo rawArgs
  isTerm <- hIsTerminalDevice stdout
  term <- lookupEnv "TERM"
  let logLevel = if _args_verbose args' then Debug else Notice
      inShellCompletion = "completion" `isInfixOf` unwords rawArgs
      notInteractive = not $ isTerm && not inShellCompletion && term /= Just "dumb"
      handleError e = (prettyNixThunkError e, ExitFailure 2)
  cliConf <- newCliConfig logLevel notInteractive notInteractive handleError
  runCli cliConf $ runThunkCommand $ _args_command args'
  exitWith ExitSuccess
