module GTL.Text (
  gtlToText
  ) where

import GTL.Parser
import qualified Data.Map as Map
import Data.List ((\\), partition, sort, intercalate, foldl')
import Data.Tree

gtlToText :: MyTree -> [String]
gtlToText tree = reverse
                $ concat
                $ reverse
                $ flatten
                $ fmap (stringify time) tree
      where
        (time, _, _, _) = rootLabel tree

stringify :: ErlTime -> (ErlTime, Dur, Pid, [BRecord]) -> [String]
stringify startGTLTs (startPidTs, _, _, rs) = lines
  where
    (_, lines) = foldl' p (startPidTs,[]) rs
    p (prevTs, lines) r = (time, line:lines)
      where
        (time, pid, m, f, a) = (rTime r, rPid r, rModule r, rFunction r, rArg r)
        diffPrev             = (time - prevTs)      `div` 1000
        diffBegin            = (time - startGTLTs) `div` 1000
        line = pid ++ " ( " ++ show diffPrev ++ " / "
                            ++ show diffBegin ++ " ) "
              ++ m ++ ":" ++ f ++ " " ++ a

