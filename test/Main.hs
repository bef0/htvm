{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
module Main where

import Test.Tasty (TestTree, testGroup, defaultMain)
import Test.Tasty.HUnit (Assertion, HasCallStack, testCase, assertBool, assertEqual, (@?=))
import Test.Tasty.QuickCheck (testProperty)
import Test.QuickCheck (property, conjoin, choose, suchThat, forAll, sublistOf,
                        label, classify, whenFail, counterexample, elements,
                        vectorOf, Gen, Testable, frequency, sized, Property,
                        arbitrary, Arbitrary, listOf)
import Test.QuickCheck.Monadic (forAllM, monadicIO, run, assert, wp)

import Control.Monad (when)
import Data.Functor.Foldable (Fix(..), Recursive(..), Corecursive(..))
import Data.Maybe (fromMaybe)
import Data.Text (isInfixOf)
import Data.Monoid ((<>))
import Foreign (Storable(..))
import System.Directory (getTemporaryDirectory)
import System.IO.Temp (withTempFile)
import Prelude

import HTVM.Prelude
import HTVM

genTensorList1 :: (Arbitrary e) => Gen [e]
genTensorList1 = do
    x <- choose (0,10)
    vectorOf x $ arbitrary

genTensorList2 :: (Arbitrary e) => Gen [[e]]
genTensorList2 = do
    x <- choose (0,10)
    y <- choose (0,10)
    vectorOf x $ vectorOf y $ arbitrary

genShape :: Gen [Integer]
genShape = do
  ndim <- choose (0,4)
  vectorOf ndim (choose (0,5))


class EpsilonEqual a where
  epsilonEqual :: Rational -> a -> a -> Bool

instance EpsilonEqual Float where epsilonEqual eps a b = abs (a - b) < fromRational eps
instance EpsilonEqual Double where epsilonEqual eps a b = abs (a - b) < fromRational eps
instance EpsilonEqual a => EpsilonEqual [a] where
  epsilonEqual eps a b =
    length a == length b && (all (uncurry (epsilonEqual eps)) (a`zip`b))

instance EpsilonEqual TensorData where
  epsilonEqual eps a b =
    case td_type a == td_type b of
      False -> False
      True ->
        case tvmCode $ toTvmDataType $ td_type a of
          KDLInt -> td_data a == td_data b
          KDLUInt -> td_data a == td_data b
          KDLFloat ->
            all (uncurry $ epsilonEqual eps) (flatternFloat a`zip`flatternFloat b)

assertEpsilonEqual :: (EpsilonEqual a, HasCallStack) => String -> Rational -> a -> a -> Assertion
assertEpsilonEqual msg eps a b = assertBool msg (epsilonEqual eps a b)

withTestModule :: Stmt Function -> (ModuleLib -> IO b) -> IO b
withTestModule mf act =
  withTmpf "htvm-test-module" $ \fp -> do
    {- traceM $ "file: " <> fp -}
    act =<< do
      buildModule defaultConfig fp $
        stageModule $ do
          f <- mf
          modul [f]

withSingleFuncModule :: ModuleLib -> (TVMFunction -> IO b) -> IO b
withSingleFuncModule modlib handler =
  case modlib of
    (ModuleLib modpath (Module [Function nm _] _)) ->
      withModule modpath $ \hmod ->
      withFunction nm hmod $ \hfun ->
        handler hfun
    _ -> fail "withSingleFuncModule expects module with single function"

singleFuncModule :: ModuleLib -> IO TVMFunction
singleFuncModule modlib =
  case modlib of
    (ModuleLib modpath (Module [Function nm _] _)) -> do
      m <- loadModule modpath
      f <- loadFunction nm m
      return f
    _ -> fail "withSingleFuncModule expects module with single function"

withTestFunction :: Stmt Function -> (TVMFunction -> IO b) -> IO b
withTestFunction mf handler = withTestModule mf $ flip withSingleFuncModule handler

shouldCompile :: Stmt Function -> IO ()
shouldCompile = flip withTestFunction (const $ return ())

modelProperty :: ModuleLib -> Gen ([TVMTensor],TVMTensor) -> Property
modelProperty modlib gen =
  monadicIO $ do
    func <- run $ singleFuncModule modlib
    forAllM gen $ \(args,expected) -> do
      actual <- run $ newEmptyTensor (toTvmDataType $ tensorDataType @Float) (tvmTensorShape expected) KDLCPU 0
      run $ callTensorFunction actual func args
      (a :: TensorData) <- run $ peekTensor actual
      (e :: TensorData) <- run $ peekTensor expected
      assert $ (epsilonEqual epsilon a e)


{-
testFunction :: forall d1 i1 e1 d2 i2 e2 . (TVMData d1 i1 e1, TVMData d2 i2 e2) =>
  [Integer] -> ([Integer] -> Stmt Function) -> (d1 -> d2) -> PropertyM IO a
testFunction ishape func_ut func_checker =
  withTestModule (func_ut ishape) $
    \(ModuleLib p m) -> do
      withModule p $ \hmod -> do
      withFunction (funcName $ head $ modFuncs $ m) hmod $ \fmod -> do
        a <- liftIO $ newEmptyTensor @e1 ishape KDLCPU 0
        c <- liftIO $ newEmptyTensor @e2 oshape KDLCPU 0
        forAllM arbitrary $ \x -> do
          liftIO $ callTensorFunction c fmod [a]
          c_ <- liftIO $ peekTensor c
          assertEpsilonEqual "Function result" epsilon [[6.0::Float]] c_
-}

epsilon :: Rational
epsilon = 1e-5

flatzero2 :: [[e]] -> [[e]]
flatzero2 x | length (concat x) == 0 = []
            | otherwise = x

main :: IO ()
main = defaultMain $
    testGroup "All" $ reverse [

      testGroup "Uninitialized Tensor FFI should work" $
        let
          go :: forall e . TensorDataTypeRepr e => [Integer] -> IO ()
          go sh = do
            a <- newEmptyTensor (toTvmDataType $ tensorDataType @e) sh KDLCPU 0
            assertEqual "poke-peek-2" (tvmTensorNDim a) (ilength sh)
            assertEqual "poke-peek-1" (tvmTensorShape a) sh

          gen :: forall e . TensorDataTypeRepr e => Property
          gen = forAll genShape $ monadicIO . run . go @e
        in [
          testProperty "Int32"  $ (gen @Int32)
        , testProperty "Word32" $ (gen @Word32)
        , testProperty "Float"  $ (gen @Float)
        , testProperty "Int64"  $ (gen @Int64)
        , testProperty "Word64" $ (gen @Word64)
        , testProperty "Double" $ (gen @Double)
        ]

    , testGroup "Initiallized Tensor FFI should work" $
        let
          go :: forall d . (TVMData d, Eq d, Show d) => d -> IO ()
          go l = do
            a <- newTensor l KDLCPU 0
            assertEqual "poke-peek-1" (tvmTensorNDim a) (tvmDataNDim l)
            assertEqual "poke-peek-2" (tvmTensorShape a) (tvmDataShape l)
            l2 <- peekTensor a
            assertEqual "poke-peek-3" l l2
            return ()

          gen1 :: forall e . (Storable e, Eq e, Show e, Arbitrary e, TVMData [e]) => Property
          gen1 = forAll (genTensorList1 @e) $ monadicIO . run . go

          gen2 :: forall e . (Storable e, Eq e, Show e, Arbitrary e, TensorDataTypeRepr e) => Property
          gen2 = forAll (genTensorList2 @e) $ monadicIO . run . go . flatzero2
        in [
          testProperty "[Int32]"      $ (gen1 @Int32)
        , testProperty "[Word32]"     $ (gen1 @Word32)
        , testProperty "[Float]"      $ (gen1 @Float)
        , testProperty "[Int64]"      $ (gen1 @Int64)
        , testProperty "[Word64]"     $ (gen1 @Word64)
        , testProperty "[Double]"     $ (gen1 @Double)
        , testProperty "[[Int32]]"    $ (gen2 @Int32)
        , testProperty "[[Word32]]"   $ (gen2 @Word32)
        , testProperty "[[Float]]"    $ (gen2 @Float)
        , testProperty "[[Int64]]"    $ (gen2 @Int64)
        , testProperty "[[Word64]]"   $ (gen2 @Word64)
        , testProperty "[[Double]]"   $ (gen2 @Double)
        ]

    {-
    , testGroup "Flattern representation should be correct" $
        let
          go :: forall d i e . (TVMData d i e, Eq e, Show e, Eq d, Show d, Storable e) => d -> IO ()
          go l = do
            a <- newTensor l KDLCPU 0
            f <- peekTensor @(FlatternTensor e) a
            assertEqual "Failed!" f (flatternTensor l)
            return ()

          gen2 :: forall e i . (Eq e, Show e, TVMData [[e]] i e, Arbitrary e, Storable e) => Property
          gen2 = forAll (genTensorList2 @e) $ monadicIO . run . go . flatzero2
        in [
          testProperty "[[Float]]"  $ (gen2 @Float)
        , testProperty "[[Double]]" $ (gen2 @Double)
        ]
        -- ??? Works ???
    -}

    , testGroup "Copy FFI should work for tensors" $
        let
          go :: forall d . (TVMData d, Eq d, Show d) => d -> IO ()
          go l = do
            src <- newTensor l KDLCPU 0
            dst <- newEmptyTensor (tvmTensorTvmDataType src) (tvmTensorShape src) KDLCPU 0
            tvmTensorCopy dst src
            l2 <- peekTensor dst
            assertEqual "copy-peek-1" l l2
            return ()

          gen1 :: forall e . (Eq e, Show e, TVMData [e], Arbitrary e) => Property
          gen1 = forAll (genTensorList1 @e) $ monadicIO . run . go

          gen2 :: forall e . (Eq e, Show e, TensorDataTypeRepr e, Storable e, Arbitrary e) => Property
          gen2 = forAll (genTensorList2 @e) $ monadicIO . run . go . flatzero2
        in [
          testProperty "[Int32]"      $ (gen1 @Int32)
        , testProperty "[Word32]"     $ (gen1 @Word32)
        , testProperty "[Float]"      $ (gen1 @Float)
        , testProperty "[Int64]"      $ (gen1 @Int64)
        , testProperty "[Word64]"     $ (gen1 @Word64)
        , testProperty "[Double]"     $ (gen1 @Double)
        , testProperty "[[Int32]]"    $ (gen2 @Int32)
        , testProperty "[[Word32]]"   $ (gen2 @Word32)
        , testProperty "[[Float]]"    $ (gen2 @Float)
        , testProperty "[[Int64]]"    $ (gen2 @Int64)
        , testProperty "[[Word64]]"   $ (gen2 @Word64)
        , testProperty "[[Double]]"   $ (gen2 @Double)
        ]

    , testCase "Compiler (g++ -ltvm) should be available" $ do
        withTmpf "htvm-compiler-test" $ \x -> do
          _ <- compileModuleGen defaultConfig x (ModuleGenSrc undefined "int main() { return 0; }")
          return ()

    , testCase "Pretty-printer (clang-format) should be available" $ do
        _ <- prettyCpp "int main() { return 0; }"
        return ()

    , testCase "Function printer should work" $
        do
        dump <-
          printFunction defaultConfig =<< do
            stageFunctionT $ do
              s <- shapevar [10]
              function "vecadd" [("A",float32,s),("B",float32,s)] $ \[a,b] -> do
                compute s $ \e -> a![e] + b![e]
        assertBool "dump should contain 'produce' keyword" $ isInfixOf "produce" dump

    , testCase "Simple model should work, withModule/withFunction case" $
        let
          dim0 = 4 :: Integer
          fname = "vecadd"
        in do
        withTestModule (do
          s <- shapevar [fromInteger dim0]
          function fname [("A",float32,s),("B",float32,s)] $ \[a,b] -> do
            compute s $ \e -> a![e] + b![e]
          ) $
          \(ModuleLib p _) -> do
            withModule p $ \hmod -> do
            withFunction fname hmod $ \fmod -> do
              a <- newTensor @[Float] [1,2,3,4] KDLCPU 0
              b <- newTensor @[Float] [10,20,30,40] KDLCPU 0
              c <- newEmptyTensor (toTvmDataType $ tensorDataType @Float) [dim0] KDLCPU 0
              callTensorFunction c fmod [a,b]
              assertEqual "Simple model result" [11,22,33,44::Float] =<< peekTensor c

    , testCase "Simple model should work, loadModule/loadFunction case" $
        let
          dim0 = 4 :: Integer
          fname = "vecadd"
        in do
        withTestModule (do
          s <- shapevar [fromInteger dim0]
          function fname [("A",float32,s),("B",float32,s)] $ \[a,b] -> do
            compute s $ \e -> a![e] + b![e]
          ) $
          \(ModuleLib mod_path _) -> do
            m <- loadModule mod_path
            f <- loadFunction "vecadd" m
            a <- newTensor @[Float] [1,2,3,4] KDLCPU 0
            b <- newTensor @[Float] [10,20,30,40] KDLCPU 0
            c <- newEmptyTensor (toTvmDataType $ tensorDataType @Float) [dim0] KDLCPU 0
            callTensorFunction c f [a,b]
            assertEqual "Simple model result" [11,22,33,44::Float] =<< peekTensor c

    , testCase "Reduce axis operation should compile" $

        shouldCompile $ do
          s <- shapevar [4]
          function "reduce" [("A",float32,s)] $ \[a] -> do
            IterVar r <- reduce_axis (0,3)
            compute ShapeScalar $ \(_::Expr) -> esum (a![r], [r])

    , testCase "Conv2d operation should compile" $

        shouldCompile $ do
          sa <- shapevar [1,1,10,10]
          sk <- shapevar [1,1,3,3]
          function "reduce" [("A",float32,sa), ("k",float32,sk)] $ \[a,k] -> do
            return $ conv2d_nchw a k def

    , testCase "Pad operation should compile" $

        shouldCompile $ do
          sa <- shapevar [1,1,10,10]
          function "reduce" [("A",float32,sa) ] $ \[a] -> do
            return $ pad a def{pad_value=33, pad_before=[2,2,2,2]}

    , testCase "Parallel schedule should compile" $

        shouldCompile $ do
          sa <- shapevar [1,1,10,10]
          function "reduce" [("A",float32,sa) ] $ \[a] -> do
            c <- assign $ pad a def{pad_value=33, pad_before=[2,2,2,2]}
            r <- axisId c 0
            s <- schedule [c]
            parallel s c r
            return c

    , testCase "Sigmoid primitive should work" $

        withTestFunction (do
          s <- shapevar [4]
          function "sigmoid" [("A",float32,s)] $ \[a] -> do
            c <- assign $ sigmoid a
            return c
          ) $
          \fmod ->
            let
              inp = [1,2,3,4] :: [Float]
              out = map (\x -> 1.0 / (1.0 + exp (- x))) inp
            in do
            a <- newTensor @[Float] [1,2,3,4] KDLCPU 0
            c <- newEmptyTensor (toTvmDataType $ tensorDataType @Float) [4] KDLCPU 0
            callTensorFunction c fmod [a]
            c_ <- peekTensor c
            assertEpsilonEqual "Simple model result" epsilon out c_

    , testCase "Split primitive should compile" $

        shouldCompile $ do
          sa <- shapevar [2,4]
          function "reduce" [("A",float32,sa) ] $ \[a] -> do
            c <- assign $ split a [1] 0
            return (c!0)

    , testCase "Differentiate should work" $

        withTestFunction (do
          sa <- shapevar [1]
          function "difftest" [("A",float32,sa) ] $ \[a] -> do
            c <- compute sa $ \i -> (a![i])*(a![i])
            dc <- assign $ differentiate c [a]
            return (dc!0)
          ) $
          \func -> do
            a <- newTensor @[Float] [3.0] KDLCPU 0
            c <- newEmptyTensor (toTvmDataType $ tensorDataType @Float) [1,1] KDLCPU 0
            callTensorFunction c func [a]
            c_ <- peekTensor c
            assertEpsilonEqual "Differentiate result" epsilon [[6.0::Float]] c_
    ]

