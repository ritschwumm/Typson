{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad (void)
import           Control.Monad.Catch (handleAll)
import qualified Data.ByteString.Char8 as BS
import           Data.List (sort)
import qualified Database.Esqueleto as E
import qualified Database.Esqueleto.PostgreSQL.JSON as E
import qualified Database.Persist.Postgresql as P
import qualified Database.PostgreSQL.Simple as Pg
import           Lens.Micro
import qualified Hedgehog.Gen as HH
import qualified Hedgehog.Range as HH
import           System.Environment (lookupEnv)
import           Test.Tasty
import           Test.Tasty.HUnit

import           Typson
import           Typson.Esqueleto
import           Typson.Test.Esqueleto.DbSchema (EsqueletoEntity(..), EntityField(EsqueletoEntityGraph), migrateAll)
import           Typson.Test.Generators
import           Typson.Test.Types

main :: IO ()
main = defaultMain esqueletoTestTree

esqueletoTestTree :: TestTree
esqueletoTestTree = withRunDb $ \runDb ->
  testGroup "Esqueleto Tests"
  [ testCase "JSON Queries" $ do
      graphs <- HH.sample (HH.list (HH.singleton 100) bazGen)
      runDb (insertData graphs)

      r1 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath basicPath1 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a1 = flip map graphs $ \g -> E.Value . NullableJSONB $
                 g ^. fieldLens (key @"baz1") bazJ
                    . fieldLens (key @"bar3") barJ
      assertEqual "Basic Path 1" (sort r1) (sort a1)

      r2 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath basicPath2 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a2 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^. fieldLens (key @"baz1") bazJ
               . fieldLens (key @"bar1") barJ
               . fieldLens (key @"foo3") fooJ
      assertEqual "Basic Path 2" (sort r2) (sort a2)

      r3 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath basicPath3 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a3 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^. fieldLens (key @"baz1") bazJ
      assertEqual "Basic Path 3" (sort r3) (sort a3)

      r4 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath optionalPath1 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a4 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz1") bazJ
               . fieldLens (key @"bar2") barJ
               . _Just
               . fieldLens (key @"foo4") fooJ
      assertEqual "Optional Path 1" (sort r4) (sort a4)

      r5 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath optionalPath2 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a5 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz1") bazJ
               . fieldLens (key @"bar2") barJ
               . _Just
               . fieldLens (key @"foo2") fooJ
               . _Just
      assertEqual "Optional Path 2" (sort r5) (sort a5)

      r6 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath optionalPath3 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a6 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz2") bazJ
               . _Just
               . fieldLens (key @"bar1") barJ
               . fieldLens (key @"foo2") fooJ
               . _Just
      assertEqual "Optional Path 3" (sort r6) (sort a6)

      r7 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath listIdxPath1 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a7 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz1") bazJ
               . fieldLens (key @"bar1") barJ
               . fieldLens (key @"foo1") fooJ
               . ix 2
      assertEqual "List Idx Path 1" (sort r7) (sort a7)

      r8 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath listIdxPath2 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a8 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz3") bazJ
               . ix 0
               . fieldLens (key @"foo3") fooJ
      assertEqual "List Idx Path 2" (sort r8) (sort a8)

      r9 <- runDb . E.select . E.from $ \entity ->
              pure . jsonPath listIdxPath3 (getObjectTree bazJ)
                $ entity E.^. EsqueletoEntityGraph
      let a9 = flip map graphs $ \g -> E.Value . NullableJSONB $
            g ^? fieldLens (key @"baz3") bazJ
               . ix 0
               . fieldLens (key @"foo1") fooJ
               . ix 1
      assertEqual "List Idx Quer 3" (sort r9) (sort a9)
  ]

type DbRunner = forall b. P.SqlPersistT IO b -> IO b

withRunDb :: (DbRunner -> TestTree) -> TestTree
withRunDb mkTree = withDb $ \ioBackend -> mkTree $ \action -> do
  backend <- ioBackend
  P.runSqlConn action backend

withDb :: (IO P.SqlBackend -> TestTree) -> TestTree
withDb = withResource connectToDb P.connClose

connectToDb :: IO P.SqlBackend
connectToDb = do
  Just connString <- lookupEnv "CONN_STRING"
  conn <- Pg.connectPostgreSQL $ BS.pack connString
  backend <- P.openSimpleConn (\_ _ _ _ -> pure ()) conn

  -- reset the table
  _ <- handleAll (const $ pure 0) $ Pg.execute_ conn "DROP TABLE \"esqueleto_entity\""

  P.runSqlConn (P.runMigration migrateAll) backend

  pure backend

insertData :: [Baz] -> P.SqlPersistT IO ()
insertData graphs =
  void $ P.insertMany (EsqueletoEntity . E.JSONB <$> graphs)