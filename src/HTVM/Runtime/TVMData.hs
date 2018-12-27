-- | DLPack message wrappers to pass data to/from TVM models

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE FlexibleContexts #-}

module HTVM.Runtime.TVMData where

import qualified Data.Array as Array

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Arrow ((***))
import Data.Array (Array(..))
import Data.Word (Word8,Word16,Word32,Word64)
import Data.Int (Int8,Int16,Int32,Int64)
import Data.Text (Text)
import Data.List (nub)
import Foreign (newForeignPtr, Ptr, Storable(..), alloca,
                allocaArray, peek, poke, peekArray, pokeArray,
                castPtr, advancePtr, malloc, mallocArray,
                withForeignPtr, Storable(..))

import HTVM.Prelude
import HTVM.Runtime.FFI


class TVMIndex i where
  tvmList :: i -> [Integer]

instance TVMIndex Integer where tvmList a = [a]
instance TVMIndex (Integer,Integer) where tvmList (a,b) = [a,b]
instance TVMIndex (Integer,Integer,Integer) where tvmList (a,b,c) = [a,b,c]
instance TVMIndex (Integer,Integer,Integer,Integer) where tvmList (a,b,c,d) = [a,b,c,d]

instance TVMIndex [Integer] where tvmList = id

tvmIndexDims :: (TVMIndex i) => i -> Integer
tvmIndexDims = ilength . tvmList

-- TODO: introduce  `nativeTypeInfo :: TVMDataType`
class TVMElemType e where
  tvmTypeCode :: TVMDataTypeCode
  tvmTypeBits :: Integer
  -- | Make a parameter of type
  tvmTypeLanes :: Integer

tvmDataType :: forall e . (TVMElemType e) => TVMDataType
tvmDataType = TVMDataType (tvmTypeCode @e) (tvmTypeBits @e) (tvmTypeLanes @e)

instance TVMElemType Int32  where tvmTypeCode = KDLInt; tvmTypeBits = 32; tvmTypeLanes = 1
instance TVMElemType Word32 where tvmTypeCode = KDLUInt; tvmTypeBits = 32; tvmTypeLanes = 1
instance TVMElemType Float  where tvmTypeCode = KDLFloat; tvmTypeBits = 32; tvmTypeLanes = 1
instance TVMElemType Int64  where tvmTypeCode = KDLUInt; tvmTypeBits = 64; tvmTypeLanes = 1
instance TVMElemType Word64 where tvmTypeCode = KDLUInt; tvmTypeBits = 64; tvmTypeLanes = 1
instance TVMElemType Double where tvmTypeCode = KDLFloat; tvmTypeBits = 64; tvmTypeLanes = 1

-- | Data bundle accepted by TVM model. @d@ is type of data, @i@ is a type of
-- index, @e@ is the type of element
--
-- TODO: introduce `typeInfo :: d -> TVMDataType` which may or may not use `nativeTypeInfo`
class (TVMIndex i, TVMElemType e) => TVMData d i e | d -> i, d -> e where
  flattern :: d -> [e]
  -- ^ Get the flattern representation, where each list item represents tensor
  -- item.  Note, that length of that list may be greater than length of
  -- C-array accepted by `tvmPeek` and `tvmPoke` if the type has lane>1
  tvmIShape :: d -> [Integer]
  -- ^ Get the shape of data, in form of list of inegers
  tvmIndex :: d -> i -> IO e
  -- ^ Access data element by its index
  -- TODO: Consider removing this function. Instance should define their own indexation
  tvmPeek :: [Integer] -> Ptr e -> IO d
  -- ^ Take the shape and the pointer to dense memory area, produce the data container
  -- TODO: Accept byte-pointer instead of `Ptr e`
  tvmPoke :: d -> Ptr e -> IO ()
  -- ^ Write the contents of container to dense memory area.
  -- TODO: figure out the alignment restirctions.
  -- TODO: Accept byte-pointer instead of `Ptr e`

instance (Storable e, Array.Ix i, TVMIndex i, TVMElemType e) => TVMData (Array i e) i e where
  flattern = error "FIXME: flattern is not implemented for Data.Array"
  tvmIShape = map (uncurry (-)) . uncurry zip . (tvmList *** tvmList) . Array.bounds
  tvmIndex d i = pure $ d Array.! i
  tvmPoke d ptr = pokeArray ptr (Array.elems d)
  tvmPeek shape ptr = error "FIXME: tvmPeek is not implemented for Data.Array"

tvmIShape1 d = [ilength d]
tvmIndex1 l i = pure $ l !! (fromInteger i)
tvmPoke1 d ptr = pokeArray ptr d
tvmPeek1 [x] ptr = peekArray (fromInteger x) ptr
tvmPeek1 _ ptr = error "tvmPeek1 should be called with a single-element shape"
instance TVMData [Int32] Integer Int32   where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id
instance TVMData [Word32] Integer Word32 where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id
instance TVMData [Float] Integer Float   where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id
instance TVMData [Int64] Integer Int64   where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id
instance TVMData [Word64] Integer Word64 where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id
instance TVMData [Double] Integer Double where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1; tvmPeek = tvmPeek1 ; flattern = id

tvmIShape2 [] = [0,0]
tvmIShape2 d = [ilength d, ilength (head d)]
tvmIndex2 l (r,c) = pure $ l !! (fromInteger r) !! (fromInteger c)
tvmPoke2 d ptr
  | length d == 0 = pokeArray ptr (concat d)
  | length (nub (map length d)) == 1 = pokeArray ptr (concat d)
  | otherwise = error "All elements should have the same length"
tvmPeek2 [0,0] ptr = pure []
tvmPeek2 [x,y] ptr = group y <$>  peekArray (fromInteger $ x*y) ptr where
  group :: Integer -> [a] -> [[a]]
  group _ [] = []
  group n l
    | n > 0 = (take (fromInteger n) l) : (group n (drop (fromInteger n) l))
    | otherwise = error "Negative n"
tvmPeek2 x _ = error "tvmPeek2 should be called with 2-element shape"
flattern2 = concat
instance TVMData [[Int32]] (Integer,Integer) Int32 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2
instance TVMData [[Word32]] (Integer,Integer) Word32 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2
instance TVMData [[Float]] (Integer,Integer) Float where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2
instance TVMData [[Int64]] (Integer,Integer) Int64 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2
instance TVMData [[Word64]] (Integer,Integer) Word64 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2
instance TVMData [[Double]] (Integer,Integer) Double where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2; tvmPeek = tvmPeek2 ; flattern = flattern2

tvmDataShape :: (TVMData d i e) => d -> [Integer]
tvmDataShape = tvmIShape

tvmDataNDim :: (TVMData d i e) => d -> Integer
tvmDataNDim = ilength . tvmDataShape


-- | Flattern Tensor is a container which stores its elements in 1D-array
data FlatternTensor e = FlatternTensor {
    ft_shape :: [Integer]
  , ft_data :: [e]
  } deriving(Read,Show,Ord,Eq)

flatternTensor :: TVMData d i e => d -> FlatternTensor e
flatternTensor d = FlatternTensor (tvmIShape d) (flattern d)

instance (Storable e, TVMElemType e) => TVMData (FlatternTensor e) [Integer] e where
  tvmIShape = ft_shape
  tvmIndex d i = pure $ ft_data d !! (fromInteger $ snd $ foldr (\(i,s) (vol,res) -> (vol*s, vol*i+res)) (1,0) (i`zip`(tail $ ft_shape d <> [1])))
  tvmPeek shape ptr = FlatternTensor <$> pure shape <*> tvmPeek1 [foldr1 (*) shape] ptr
  tvmPoke (FlatternTensor sh d) ptr = tvmPoke1 d ptr
  flattern = ft_data

-- | Create new empty TVMTensor object. This object will be managed by Haskell
-- runtime which would call free when it decides to do so.
--
-- FIXME: non-CPU devices will not work, see FIXME in `pokeTensor`
newEmptyTensor :: forall e . (TVMElemType e)
  => [Integer]                   -- ^ Shape
  -> TVMDeviceType               -- ^ Device type (CPU|GPU|etc)
  -> TVMDeviceId                 -- ^ Device ID
  -> IO TVMTensor
newEmptyTensor shape dt did =
  let
    ndim = length shape
  in do
  alloca $ \pt -> do
  allocaArray ndim $ \pshape -> do
    pokeArray pshape (map (fromInteger . toInteger) shape)
    r <-
      tvmArrayAlloc
        pshape
        (fromInteger $ toInteger $ ndim)
        (toCInt $ fromEnum $ tvmTypeCode @e)
        (toCInt $ tvmTypeBits @e)
        (toCInt $ tvmTypeLanes @e)
        (toCInt $ fromEnum dt)
        (toCInt $ did) pt
    case r of
      0 -> peek pt >>= newForeignPtr tvmArrayFree_
      e -> throwIO (TVMAllocFailed (fromCInt e))

-- | Allocate new Tensor object
newTensor :: forall d i e . (TVMData d i e)
  => d                           -- ^ TvmData tensor-like object
  -> TVMDeviceType               -- ^ Device type
  -> TVMDeviceId                 -- ^ Device ID
  -> IO TVMTensor
newTensor d dt did = do
  ft <- newEmptyTensor @e (map fromInteger $ tvmDataShape d) dt did
  withForeignPtr ft $ \pt -> do
    tvmPoke d (castPtr (unsafeTensorData ft))
  return ft

-- | Transfer data from TVMTensor to TVMData instance
peekTensor :: forall d i e . (TVMData d i e)
  => TVMTensor -> IO d
peekTensor ft = do
  when (tensorDataType ft /= tvmDataType @e) $
    throwIO (TypeMismatch (tensorDataType ft) (tvmDataType @e))
  case tensorDevice ft of
    KDLCPU -> do
      tvmPeek (tensorShape ft) (castPtr (unsafeTensorData ft))
    x -> do
      allocaArray (fromInteger $ tensorSize ft) $ \parr -> do
      withForeignPtr ft $ \pt -> do
        _ <- tvmArrayCopyToBytes pt parr (toCSize $ tensorSize ft)
        tvmPeek (tensorShape ft) (castPtr parr)

-- | Transfer data from TVMData instance to TVMTensor
pokeTensor :: forall d i e . (TVMData d i e)
  => TVMTensor -> d -> IO ()
pokeTensor ft d = do
  when (tensorShape ft /= tvmDataShape d) $
    throwIO (PokeShapeMismatch (tensorShape ft) (tvmDataShape d))
  when (tensorDataType ft /= tvmDataType @e) $
    throwIO (TypeMismatch (tensorDataType ft) (tvmDataType @e))
  case tensorDevice ft of
    KDLCPU -> do
      tvmPoke d (castPtr (unsafeTensorData ft))
    x -> do
      allocaArray (fromInteger $ tensorSize ft) $ \parr -> do
      withForeignPtr ft $ \pt -> do
        tvmPoke d (castPtr parr)
        _ <- tvmArrayCopyFromBytes pt parr (toCSize $ tensorSize ft)
        return ()

