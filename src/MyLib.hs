{-# LANGUAGE OverloadedLabels, ViewPatterns, TemplateHaskell, QuasiQuotes #-}

module MyLib (someFunc) where

import Control.Monad.IO.Class
import Data.Text (Text)
import qualified Data.Text as T
import Database.Persist
import Database.Persist.Sqlite (runSqlite, runMigrationSilent)
import Database.Persist.TH (mkPersist, mkMigrate, persistLowerCase, share, sqlSettings)
import Database.Persist.Sql (rawQuery, insert)
import Data.Proxy
import Data.IORef
import GHC.Generics
--import Servant.API
import Servant
import Network.Wai
import Network.Wai.Handler.Warp
import Control.Lens
import Data.Generics.Product
import Data.Aeson
import Data.Aeson.Types
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TVar
import Control.Monad.STM
import Control.Monad
import Control.Concurrent
import qualified StmContainers.Map as TMap
import qualified Focus
-- MTL
import Control.Monad.Except
import Control.Monad.Reader
import Control.Applicative
--import Data.Generics.Sum

fmap2 = fmap . fmap

liftSTM = lift . lift

share [mkPersist sqlSettings, mkMigrate "migrateTables"] [persistLowerCase|
  Writings
    content Text
|]

-- TMapMap isn't actually a pure Map or anything but rather a TVar mapified
-- this is a temporary DB replacement, the authors should change the name
type TMap = TMap.Map

-- these operations are for operational transformation, necessary for collaborative editing
data Operation = RetainOp Int | AddStringOp Text | DelCharsOp Int deriving (Generic, Show)
instance ToJSON Operation
instance FromJSON Operation

data Document = Document {position :: Int, content :: Text} deriving (Generic, Show)
-- config is actually the wrong name, these are references passed around
type Config = (TMap.Map Int Document, TQueue (Int, Operation))
type Stack = ExceptT ServerError (ReaderT Config STM)

-- this is awkward and not ideal, isn't this just a natural transformation?
stackToHandler :: Config -> Stack a -> Handler a -- ExceptT ServerError IO a
stackToHandler config (ExceptT stackinner) = Handler (ExceptT stichedup)
  where stichedup = atomically $ runReaderT stackinner config

type WritingAPI = "doc" :> Capture "document" Int :> Get '[JSON] (Maybe Text)
  :<|> "send-doc" :> Capture "document" Int :> ReqBody '[JSON] Text :> Post '[JSON] ()
  :<|> "submit-op" :> Capture "document" Int :> ReqBody '[JSON] Operation :> Post '[JSON] ()

kt :: Document -> Int
kt x = x ^. (field @"position")

retain :: Int -> Document -> Document
retain n = field @"position" %~ (+n)

addString :: Text -> Document -> Document
addString str (Document cursor txt) = Document (cursor + T.length str) (preCursor <> txt <> postCursor)
  where (preCursor, postCursor) = T.splitAt cursor txt

delCharacters :: Int -> Document -> Document
delCharacters n (Document cursor txt) = Document (cursor - n) (T.drop n preCursor <> postCursor)
  where (preCursor, postCursor) = T.splitAt cursor txt

server' :: ServerT WritingAPI Stack
server' = getdoc :<|> postdoc :<|> submitOp
  where getdoc :: Int -> Stack (Maybe Text)
        getdoc ident = do
          (docMap, _) <- ask
          liftSTM $ fmap2 content $ TMap.lookup ident docMap

        postdoc :: Int -> Text -> Stack ()
        postdoc ident updated = do
          (docMap, _) <- ask
          liftSTM $ TMap.insert (Document 0 updated) ident docMap

        submitOp :: Int -> Operation -> Stack ()
        submitOp ident op = do
          (_, queue) <- ask
          liftSTM $ writeTQueue queue (ident, op)

writingApp :: Config -> Application
writingApp config = serve (Proxy @ WritingAPI) $ hoistServer (Proxy @ WritingAPI) (stackToHandler config) server'

processOp :: TMap Int Document -> (Int, Operation) -> STM ()
processOp tmap (ident, op) = TMap.focus (Focus.adjust modifier) ident tmap >> pure ()
  where modifier = case op of
                     RetainOp n -> retain n
                     AddStringOp txt -> addString txt
                     DelCharsOp n -> delCharacters n

processQueue :: Config -> STM ()
processQueue (tmap, queue) = forever $ peekTQueue queue >>= processOp tmap

someFunc :: IO ()
someFunc = do
  config :: Config <- liftA2 (,) TMap.newIO newTQueueIO
  -- whilst this uses a greenthread it could actually be a different OS thread so we need atomics
  processQueueThread <- forkIO (atomically $ processQueue config)
  run 8081 (writingApp config)
