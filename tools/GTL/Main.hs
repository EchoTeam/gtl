{-# LANGUAGE TypeSynonymInstances #-}
-- vim: set ts=2 sts=2 sw=2 et:
--
-- Script to parse gtl-log files
--
-- To compile it do:
--   make
--
--
import System.Environment (getArgs)
import System.Console.GetOpt
import System.Exit
import System.IO (stdin, openFile, IOMode(..))
import Data.List ((\\), partition, sort, intercalate, foldl')
import Data.Tree
import Data.Maybe (fromMaybe, maybeToList)
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as C8
import Control.Monad

import GTL.Parser
import GTL.SVG
import GTL.Text

-- for debug
import Debug.Trace
--import System.IO.Unsafe(unsafePerformIO)

version = "0.1"
name = "gtl-analyzer"

data Repr = PlainRepr | SVGRepr deriving (Eq)
data Options = Options  {
    representation  :: Repr,
    grepBefore      :: [(String,String)],
    grepAfter       :: [(String,String)],
    startPhase      :: Maybe (String,String),
    filterString    :: [String],
    filterIdx       :: [Int]
  }

defaultOptions = Options {
    representation  = PlainRepr,
    grepAfter       = mzero,
    grepBefore      = mzero,
    startPhase      = mzero,
    filterString    = mzero,
    filterIdx       = mzero
  }

options :: [OptDescr (Options -> IO Options)]
options = [
    Option []    ["svg"]          (NoArg $ setReprOpt SVGRepr)
        "output 'svg' representation (svg-file)",
    Option []    ["plain"]        (NoArg $ setReprOpt PlainRepr)
        "output 'plain' representation (default)",
    Option ['i'] ["index"]        (OptArg setFilterIdx "IDX")
        "print info only for the specified gtl number",
    Option ['h'] ["help"]         (NoArg showHelp)
        "show help and exit",
    Option ['V'] ["version"]      (NoArg showVersion)
        "show version number and exit"
  ]

setReprOpt r opt = return $ opt { representation = r }

setFilterIdx :: Maybe String -> Options -> IO Options
setFilterIdx mbIdx opt = return opt { filterIdx = filters }
  where filters = liftM read (maybeToList mbIdx) ++ filterIdx opt

showVersion _ = do
  putStrLn $ name ++ " " ++ version
  exitSuccess

examples = "FORMAT:\n"
  ++ "  PHASE  = \"<MODULE>[:<FUNCTION>]\"\n"
  ++ "  FILTER = \"<MODULE>[:<FUNCTION>]\"\n"
  ++ "\n"
  ++ "EXAMPLES:\n"
  ++ "   # print plain representation with start phase as_admitter : admit_events_to_storage \n"
  ++ "  " ++ name ++ " --start=as_admitter:admit_events_to_storage --filterAfter=gtl:handle_down_client --plain gtl.perftest.log\n"
  ++ "   # plain representation for debugging as_pipeline\n"
  ++ "  " ++ name ++ " --plain gtl.perftest.log --filterBefore=as_pipeline:propagate_feed --filterAfter=as_pipeline\n"
  ++ "   # svg-image representation\n"
  ++ "  " ++ name ++ " --svg gtl.perftest.log > output.svg\n"

showHelp :: a -> IO b
showHelp _ = do
  let usageStr = name ++ " " ++ version ++
        "\nUsage: gtl_analyzer [OPTIONS] <FILE>\nOPTIONS:"
  putStrLn $ usageInfo usageStr options
  putStrLn examples
  exitSuccess

main = do
  args <- getArgs
  let (actions, nonOpts, msgs) = getOpt Permute options args
  opts <- foldl' (>>=) (return defaultOptions) actions

  case msgs of
    [] -> return ()
    _  -> putStrLn (concat msgs) >> showHelp ()

  handle <- case nonOpts of
        []    -> return stdin
        (f:_) -> openFile f ReadMode
  lines <- C8.hGetContents handle
  runParser (filterFun opts) (outputGTL opts) lines


filterFunction :: (String,String) -> BRecord -> Bool
filterFunction (mod,fun) r =
  (mod == "" || rModule r   == mod) &&
  (fun == "" || rFunction r == fun)

filterFun :: Options -> BRecord -> Bool
filterFun opts r = case grepBefore opts of
      [] -> True
      filters -> any (`filterFunction` r) $ ("gtl",""):filters

outputGTL :: Options -> MyTree -> Int -> IO ()
outputGTL opts tree i | showTree  = putStrLn $ unlines repr
                      | otherwise = return ()
  where
    idxs = filterIdx    opts
    flt  = filterString opts
    searchTree = flip search tree
    showTree = (not (null idxs) && i `elem` idxs)
            || (not (null flt)  && any searchTree flt)
    repr = case representation opts of
      PlainRepr -> gtlToText tree
      SVGRepr   -> gtlToSvg tree
