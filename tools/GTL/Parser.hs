{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
-- vim: set ts=2 sts=2 sw=2 et:
module GTL.Parser (
    BObject (..),
    BRecord (..),
    ErlTime (..),
    GTL    (..),
    MyTree  (..),
    Dur     (..),
    Pid     (..),
    MFA     (..),
    Percent (..),
    pLog,
    runParser,
    search,
    recordsToTree
  ) where


import Data.Attoparsec hiding (take, takeWhile, takeTill, satisfy)
import Data.Attoparsec.Char8 (char, notChar, space, endOfInput, isSpace, endOfLine, anyChar, digit, isDigit, isAlpha_ascii, satisfy, takeTill, peekChar)
import qualified Data.ByteString.Char8 as B

import Data.List (partition, isInfixOf, intercalate, foldl')
import Data.Ord (comparing)
import Control.Applicative
import Control.Monad (when, liftM, liftM2, ap)
import Data.Tree
import Data.Char (isAsciiLower)

-- for debug
import Debug.Trace


runParser :: (BRecord -> Bool)
          -> (MyTree -> Int -> IO ())
          -> B.ByteString
          -> IO ()
runParser filterF proc lines = runParser' (parse parser lines) 0
  where
    parser = pLog filterF
    runParser' (Fail _ _ m) _     = return () -- putStrLn ("End of input " ++ m)
    runParser' (Done t r) i       = do proc r i
                                       runParser' (parse parser t) (i+1)
    runParser' res@(Partial _) i  = runParser' (feed res B.empty) (i+1)

type ErlTime = Integer

-----------------------------------------------------------------------------
--   BObject data types
-----------------------------------------------------------------------------
data BObject =  BString   String
              | BBinary   String
              | BAtom     String
              | BRef      String
              | BFun      String
              | BTuple   [BObject]
              | BArray   [BObject]
              | BInteger  String
              | BFloat    String
              | BPid      String
  deriving (Eq)

instance Searchable BObject where
  search str (BString  s) = search str s
  search str (BBinary  s) = search str s
  search str (BAtom    s) = search str s
  search str (BRef     s) = search str s
  search str (BFun     s) = search str s
  search str (BTuple   s) = or $ fmap (search str) s
  search str (BArray   s) = or $ fmap (search str) s
  search str (BInteger s) = search str s
  search str (BFloat   s) = search str s
  search str (BPid     s) = search str s

instance Show BObject where
  show (BString s)  = ["\""]            `on` s
  show (BBinary []) = "<<>>"
  show (BBinary s)  = ["<<\"", "\">>"]  `on` s
  show (BAtom s)    = ["'"]             `on` s
  show (BRef s)     = s
  show (BFun s)     = s
  show (BTuple a)   = ["{", "}"]        `on` intercalate ", " (map show a)
  show (BArray a)   = ["[", "]"]        `on` intercalate ", " (map show a)
  show (BInteger a) = show a
  show (BFloat a)   = show a
  show (BPid a)     = ["<", ">"]        `on` a

on :: [String] -> String -> String
on [l,r] s = l ++ s ++ r
on [b]   s = b ++ s ++ b

parsers = [ pTuple,
            pArray,
            pAtom,
            pRef,
            pFun,
            pBinary,
            pPid, -- can't go ahead of pBinary
            pNumber,
            pString ]

pObject :: Parser BObject
pObject = spaces *> choice parsers
{-
pObject = do
  spaces
  o <- choice parsers
  trace ("o:" ++ show(o)) $
  return o
  -}

pAtom :: Parser BObject
pAtom = liftM BAtom (nonApostrophedAtom <|> apostrophedAtom <?> "atom")
  where
    nonApostrophedAtom = liftM2 (:) lower $ many atomSymbols
    apostrophedAtom = between quote quote
    quote = char '\''

between p1 p2 = p1 >> manyTill anyChar (try p2)

lower = satisfy isAsciiLower

atomSymbols = satisfy $ \c ->
     isDigit c
  || isAlpha_ascii c
  || c == '_'
  || c == '@'

pRef :: Parser BObject
pRef = do
  try $ string $ B.pack "#Ref"
  b <- between (char '<') (char '>')
  return $ BRef $ "#Ref<" ++ b ++ ">"

pFun :: Parser BObject
pFun = do
  try $ string $ B.pack "#Fun"
  b <- between (char '<') (char '>')
  return $ BFun $ "#Fun<" ++ b ++ ">"

pString :: Parser BObject
pString = liftM BString $ between (char '"') (char '"')

pNumber :: Parser BObject
pNumber = do
    a <- many1 digit
    b <- option "" addition
    case b of
      "" -> return $ BInteger a
      _  -> return $ BFloat (a ++ b)
  where
    addition = do
      ds  <- char '.' >> many digit
      exp <- option "" (char 'e' >> many1 digit)
      case exp of
        "" -> return $ '.':ds
        _  -> return $ '.':ds ++ 'e':exp

pPid :: Parser BObject
pPid = BPid <$> between (char '<') (char '>')

pBinary :: Parser BObject
pBinary =  BBinary <$> (quoted <|> unquoted :: Parser String)
  where
    quoted    = fff "<<\"" "\">>"
    unquoted  = fff "<<" ">>"
    fff s1 s2 = between (s s1) (s s2)
    s s1      = string $ B.pack s1

pSeries :: (Char, Char) -> ([BObject] -> BObject) -> Parser BObject
pSeries (co, cc) constr = constr <$> series
  where
    series = char co *> objs <* spaces <* char cc
    objs   = pObject `sepBy` comma
    comma  = spaces >> char ',' >> spaces

pTuple, pArray :: Parser BObject
pTuple = pSeries ('{', '}') BTuple
pArray = pSeries ('[', ']') BArray

spaces = many $ satisfy $ \c ->
  isSpace c || c == '\n' || c == '\r'

line :: Parser String
line = B.unpack <$> takeTill (== '\n') <* endOfLine

gtlHeader :: Parser String
gtlHeader = try (string $ B.pack "gtl version=") >> line

skipGTLHeader :: Parser String
skipGTLHeader = do
  char '[' >> takeTill (== ']') >> anyChar >> spaces
  gtlHeader
  return "aaa"

pLog :: (BRecord -> Bool) -> Parser MyTree
pLog filterF = do
  many endOfLine
  skipGTLHeader

  (BArray els) <- pObject
  let records = map objToRec els
  let filtered = filter filterF records
  return $ recordsToTree filtered

data GTL = GTL [BRecord]
  deriving (Show, Eq)

data BRecord = BRecord {
          rPid      :: String,  -- pid of the current log
          rNode     :: String,  -- node
          rTimestr  :: String,  -- string representation of time
          rTime     :: ErlTime,
          rDur      :: Int,     -- duration in microsec
          rModule   :: String,  -- possibly module
          rFunction :: String,  -- possibly function
          rArg      :: String,  -- first argument (if short)
          rLog      :: BObject} -- log
  deriving (Show, Eq)

instance Ord BRecord where
  compare = Data.Ord.comparing rTime

class Searchable a where
  search :: String -> a -> Bool

instance Searchable String where
  search s1 s2 = s1 `isInfixOf` s2

instance Searchable BRecord where
  search str (BRecord{rPid = p, rNode = n, rLog = l}) =
       search str p
    || search str n
    || search str l

instance Searchable GTL where
  search str (GTL rs) = any (search str) rs

objToRec :: BObject -> BRecord
objToRec (BTuple (BString "0.1":ar))  = obj01ToRec ar
objToRec a = error $ "ERROR: unknown version of BObject: " ++ show a

obj01ToRec :: [BObject] -> BRecord
obj01ToRec ar = BRecord { rPid       = pidStr,
                          rNode      = nodeStr,
                          rTimestr   = timeStr,
                          rTime      = time,
                          rModule    = m,
                          rFunction  = f,
                          rArg       = a,
                          rLog       = log,
                          rDur       = 0}
  where
    [pid, node, timet, times, log]  = ar
    [pidStr, nodeStr, timeStr]      = map show [pid, node, times]
    time                            = tupleToTime timet
    [m, f, a] = objToMFA log

objToMFA :: BObject -> [String]
objToMFA log = case log of
      BTuple ls -> take 3 (map s ls ++ repeat "")
      _ -> ["", "", ""]
  where
    s (BAtom str)   = str
    s (BString str) = str
    s (BInteger i)  = show i
    s (BFloat f)    = show f
    s _             = ""

tupleToTime :: BObject -> Integer
tupleToTime (BTuple timet) = megasec * 10^12 + sec * 10^6 + microsec
  where
    [megasec, sec, microsec] = [ read t :: Integer | BInteger t <- timet ]

type Pid      = String
type Percent  = Float
type Dur      = Int -- in microsec
newtype MFA   = MFA (String, String, String)

instance Show MFA where
  show (MFA (m, f, a)) = m ++ ":" ++ f ++ "(" ++ a ++ ")"

type MyTree = Tree (ErlTime, Dur, Pid, [BRecord])

instance Searchable MyTree where
  search str node = search str  pid
            || any (search str) rs
            || any (search str) childs
    where
      Node{rootLabel = (_,_, pid, rs), subForest = childs} = node

getDuration :: [BRecord] -> Dur
getDuration rs = fromIntegral (finish - start)
  where
    rsClean  = flip filter rs $ \rec ->
                  rModule rec   /= "gtl"
               || rFunction rec == "handle_down_client"
    finish   = maximum $ map rTime rsClean
    start    = rTime   $ head rsClean

recordsToTree :: [BRecord] -> MyTree
recordsToTree rs = recordsToTree' rs dur pid
  where
    dur = getDuration rs
    pid = rPid $ head rs

-- [(Int, String)] - list of (duration, function name)
-- (Int,...) - also the overall duration
recordsToTree' :: [BRecord] -> Dur -> String -> MyTree
recordsToTree' rs sumDur pid =
  Node {rootLabel = (start, curDur, pid, fns),
        subForest = childs}
  where
    (curPidRs, nextRs) = flip partition rs $ (== pid) . rPid
    childPids = foldr filterChildPids [] curPidRs
    childs = map (recordsToTree' nextRs sumDur) childPids
    (start, dur, fns) = curPidFns curPidRs
    -- TODO: correct time scale instead of sum
    curDur = dur + case childs of
      []  -> 0
      _   -> maximum $ map (sndOf4 . rootLabel) childs
    sndOf4 (_, d,_,_) = d

filterChildPids :: BRecord -> [String] -> [String]
filterChildPids r acc = case r of
  (BRecord {rModule   = "gtl",
            rFunction = "register_child",
            rLog      = (BTuple [_,_, pid2])}) -> show pid2:acc
  _ -> acc

curPidFns :: [BRecord] -> (ErlTime, Dur,[BRecord])
curPidFns rs = (rTime $ head rs,
                getDuration rs,
                newrs)
  where
    client_down = flip filter rs $ \r ->
               rModule r   == "gtl"
            && rFunction r == "handle_down_client"
    endTime   = rTime $ head $ client_down ++ [last rs]
    notGTLRs = flip filter rs $ (/= "gtl") . rModule
    newrs     = recalcDuration endTime notGTLRs

recalcDuration :: ErlTime -> [BRecord] -> [BRecord]
recalcDuration endTime rs = newrs
  where
    (_, newrs) = foldr fun (endTime, []) rs
    fun r (nextTime, rs0) = (time, rs1)
      where
        rs1  = r { rDur = dur } : rs0
        time = rTime r
        dur  = fromIntegral $ nextTime - time

