module HTVM.Prelude
  ( module HTVM.Prelude
  , module Text.Show.Pretty
  , module Debug.Trace
  ) where

import qualified Data.Text as Text
import qualified Data.Text.IO as Text

import Text.Show.Pretty(ppShow)
import Data.Text (Text)
import Debug.Trace (traceM)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

tpack :: String -> Text
tpack = Text.pack

tunpack :: Text -> String
tunpack = Text.unpack

tputStrLn :: Text -> IO ()
tputStrLn = Text.putStrLn
