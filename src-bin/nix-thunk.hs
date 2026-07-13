import Nix.Thunk
import Nix.Thunk.Command
import Options.Applicative
import Cli.Extras
import qualified Data.Text.IO as T
import System.Environment
import System.Exit
import System.IO
import Data.List
import Data.Version (showVersion)
import Data.Void
import qualified Paths_nix_thunk as Paths

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
argsInfo = info (args <**> helper <**> versionOption) $ mconcat
  [ fullDesc
  , progDesc "Manage source repositories using Nix"
  ]

versionOption :: Parser (a -> a)
versionOption = infoOption ("nix-thunk " <> showVersion Paths.version) $ mconcat
  [ long "version"
  , help "Show version"
  ]

parserPrefs :: ParserPrefs
parserPrefs = defaultPrefs
  { prefShowHelpOnEmpty = True
  }

main :: IO ()
main =
  do
    args <- getArgs
    args' <- handleParseResult $ execParserPure parserPrefs argsInfo args
    let logLevel = if _args_verbose args' then Debug else Notice
    notInteractive <- not <$> isInteractiveTerm args
    cliConf <- newCliConfig logLevel notInteractive notInteractive (\e -> (prettyNixThunkError e, ExitFailure 1))
    runCli cliConf (runThunkCommand (_args_command args'))
  where
    isInteractiveTerm args = do
      isTerm <- hIsTerminalDevice stdout
      -- Running in bash/fish/zsh completion
      let inShellCompletion = isInfixOf "completion" $ unwords args

      -- Respect the user’s TERM environment variable. Dumb terminals
      -- like Eshell cannot handle lots of control sequences that the
      -- spinner uses.
      termEnv <- lookupEnv "TERM"
      let isDumb = termEnv == Just "dumb"

      return $ isTerm && not inShellCompletion && not isDumb
