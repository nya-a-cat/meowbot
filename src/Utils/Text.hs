{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Utils.Text
  ( T.Text, LazyText
  , lazyPack, lazyUnpack, tlshow
  , TextUtils(..)
  , ToText(..)
  ) where

import Data.Text (Text)
import Data.String(IsString)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Encoding as TE

import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TLIO
import qualified Data.Text.Lazy.Encoding as TLE

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

type LazyText = TL.Text

class TextUtils t where
  type CorrespondingByteString t
  pack :: String -> t

  unpack :: t -> String

  putTextLn :: t -> IO ()

  textToByteString :: t -> CorrespondingByteString t

  tshow :: Show a => a -> t
  tshow = pack . show
  {-# INLINE tshow #-}

instance TextUtils T.Text where
  type CorrespondingByteString T.Text = B.ByteString
  pack             = T.pack
  unpack           = T.unpack
  putTextLn        = TIO.putStrLn
  textToByteString = TE.encodeUtf8
  {-# INLINE pack #-}
  {-# INLINE unpack #-}
  {-# INLINE putTextLn #-}

instance TextUtils LazyText where
  type CorrespondingByteString LazyText = BL.ByteString
  pack             = TL.pack
  unpack           = TL.unpack
  putTextLn        = TLIO.putStrLn
  textToByteString = TLE.encodeUtf8
  {-# INLINE pack #-}
  {-# INLINE unpack #-}
  {-# INLINE putTextLn #-}

lazyPack :: String -> LazyText
lazyPack = TL.pack
{-# INLINE lazyPack #-}

lazyUnpack :: LazyText -> String
lazyUnpack = TL.unpack
{-# INLINE lazyUnpack #-}

tlshow :: Show a => a -> LazyText
tlshow = TL.pack . show
{-# INLINE tlshow #-}

-- | A class for converting values to 'Text'.
-- it avoids repetedly using 'T.pack . show' in the code, and automatically avoids using show to a Text value
class (Semigroup t, IsString t) => ToText a t where
  toText :: a -> t

instance ToText Text Text where 
  toText = id
  {-# INLINE toText #-}

instance ToText LazyText LazyText where 
  toText = id
  {-# INLINE toText #-}

instance ToText Char Text where
  toText = T.singleton
  {-# INLINE toText #-}

instance ToText Char LazyText where
  toText = TL.singleton
  {-# INLINE toText #-}

instance ToText String Text where
  toText = T.pack
  {-# INLINE toText #-}

instance ToText String LazyText where
  toText = TL.pack
  {-# INLINE toText #-}

instance ToText a Text => ToText (Maybe a) Text where
  toText Nothing  = "Nothing"
  toText (Just a) = "Just (" <> toText a <> ")"
  {-# INLINE toText #-}

instance ToText a LazyText => ToText (Maybe a) LazyText where
  toText Nothing  = "Nothing"
  toText (Just a) = "Just (" <> toText a <> ")"
  {-# INLINE toText #-}

instance {-# OVERLAPPABLE #-} Show a => ToText a Text where
  toText = T.pack . show
  {-# INLINE toText #-}

instance {-# OVERLAPPABLE #-} Show a => ToText a LazyText where
  toText = TL.pack . show
  {-# INLINE toText #-}
