{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
module Orville
  ( jsonPathSql
  , json
  , JsonSqlParts(..)
  ) where

import           Control.Monad ((<=<), join)
import           Data.Aeson (FromJSON, Result(Success), ToJSON, Value(Null), decodeStrict, encode, fromJSON)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BSL
import           Data.Proxy (Proxy(..))
import qualified Data.Text as T
import qualified Database.HDBC as HDBC
import qualified Database.Orville.PostgreSQL as O

import           JsonTreeIndexed (ObjectSYM, FieldSYM)
import           Pathing (CollapseMaybes, ReflectPath(..), TypeAtPath)

data JsonSqlParts field =
  JsonSqlParts
    { selectorString :: String
    , queryPath      :: String
    , deserializer   :: O.FromSql field
    }

jsonPathSql :: forall path o con tree field repr.
               ( CollapseMaybes (TypeAtPath o tree path) ~ field
               , ReflectPath path
               , FromJSON field
               , ToJSON field
               )
            => repr tree o
            -> O.FieldDefinition o
            -> JsonSqlParts field
jsonPathSql _ fieldDef =
  JsonSqlParts
    { selectorString = selector
    , queryPath      = T.unpack path
    , deserializer   = fromSql
    }
  where
    keys = reflectPath (Proxy :: Proxy path)
    path = T.pack (O.fieldName fieldDef) <> " -> " <> buildPath keys
    buildPath [a, b] = "'" <> a <> "' ->> '" <> b <> "'"
    buildPath [a] = "'" <> a <> "'"
    buildPath (a : rest) = "'" <> a <> "' -> " <> buildPath rest
    buildPath [] = "" -- TODO use non-empty list
    selector = T.unpack $ path <> " AS " <> "\"" <> path <> "\""
    fromSql = O.fieldFromSql
            . O.fieldOfType json
            $ T.unpack path

json :: (ToJSON a, FromJSON a) => O.SqlType a
json =
  O.SqlType
    { O.sqlTypeDDL = "JSONB"
    , O.sqlTypeReferenceDDL = Nothing
    , O.sqlTypeNullable = False
    , O.sqlTypeId = HDBC.SqlUnknownT "3802"
    , O.sqlTypeSqlSize = Nothing
    , O.sqlTypeToSql = jsonToSql
    , O.sqlTypeFromSql = jsonFromSql
    }

jsonToSql :: ToJSON a => a -> HDBC.SqlValue
jsonToSql = HDBC.SqlByteString . BSL.toStrict . encode

jsonFromSql :: FromJSON a => HDBC.SqlValue -> Maybe a
jsonFromSql = handleResult . fromJSON
          <=< valueFromSql
  where
    handleResult (Success a) = Just a
    handleResult _           = Nothing

valueFromSql :: HDBC.SqlValue -> Maybe Value
valueFromSql sql =
  case sql of
    HDBC.SqlByteString bytes -> decodeStrict bytes
    HDBC.SqlString string -> decodeStrict $ BS8.pack string
    HDBC.SqlNull -> Just Null
    _ -> Nothing

