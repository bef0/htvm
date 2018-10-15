module Demo where

import HTVM


main :: IO ()
main = do
  return ()

demo :: IO ()
demo =
  let
    s = shape [20]
  in do
  Module <$> pure "vecadd" <$> sequence [
      function "vecadd" [("A",float32,s),("B",float32,s)] $ \[a,b] -> do
        c <- compute s $ \[i] -> a![i] .+ b![i]
        d <- compute [s!0,s!0] $ \[i,j] -> c![i,i] .* c![i,i]
        e <- call "topi.relu" args [d]
        return e
    ]
