{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TupleSections     #-}
module Main where

import           Control.Applicative         (liftA2)
import           Control.Logging             (log', withStderrLogging)
import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Encode.Pretty    (encodePretty)
import           Data.Binary.Builder         (Builder)
import qualified Data.Binary.Builder         as Builder
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Lazy        as BL
import           Data.ByteString.Unsafe      (unsafeUseAsCStringLen)
import qualified Data.HashTable.IO           as H
import           Data.Map                    (Map)
import qualified Data.Map                    as M
import           Data.Maybe                  (catMaybes, fromMaybe, isJust,
                                              listToMaybe)
import           Data.Monoid                 ((<>))
import           Data.String                 (fromString)
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import qualified Database.PostgreSQL.Simple  as PG
import qualified Database.SQLite.Simple      as SQLITE
import qualified HTMLEntities.Text           as HE
import           Magic                       (MagicFlag (MagicMimeType),
                                              magicCString, magicLoadDefault,
                                              magicOpen)
import           Network.HTTP.Types          (hContentType)
import           Network.HTTP.Types.Status   (status200)
import           Network.Wai                 (Response, rawPathInfo,
                                              requestMethod, responseBuilder,
                                              responseLBS)
import           Network.Wai.Handler.Warp    (runEnv)
import           System.Environment          (getEnv, lookupEnv)
import           System.FilePath             (takeExtension)
import           Text.RE.Replace
import           Text.RE.TDFA.Text
import           Web.Fn
import qualified Web.Larceny                 as L

import qualified Shed.Blob.Email             as Email
import qualified Shed.Blob.File              as File
import qualified Shed.Blob.Permanode         as Permanode
import           Shed.BlobServer
import           Shed.BlobServer.Directory
import           Shed.BlobServer.Memory
import           Shed.Images
import           Shed.Importer
import           Shed.Indexer
import           Shed.IndexServer
import           Shed.IndexServer.Postgresql
import           Shed.IndexServer.Sqlite
import           Shed.Signing
import           Shed.Types
import           Shed.Util


type Fill = L.Fill ()
type Library = L.Library ()
type Substitutions = L.Substitutions ()

data Ctxt = Ctxt { _req     :: FnRequest
                 , _store   :: SomeBlobServer
                 , _db      :: SomeIndexServer
                 , _library :: Library
                 , _key     :: Key
                 }
instance RequestContext Ctxt where
  getRequest = _req
  setRequest c r = c { _req = r }

render :: Ctxt -> Text -> IO (Maybe Response)
render ctxt = renderWith ctxt mempty

renderWith :: Ctxt -> Substitutions -> Text -> IO (Maybe Response)
renderWith ctxt subs tpl =
  do t <- L.renderWith (_library ctxt) subs () (T.splitOn "/" tpl)
     case t of
       Nothing -> return Nothing
       Just t' -> okHtml t'


initializer :: IO Ctxt
initializer = do
  lib <- L.loadTemplates "templates" L.defaultOverrides
  pth' <- fmap T.pack <$> (lookupEnv "BLOBS")
  (store, pth) <- case pth' of
                    Just pth'' -> return (SomeBlobServer (FileStore pth''), pth'')
                    Nothing    -> do
                      ht <- H.new
                      return (SomeBlobServer (MemoryStore ht), ":memory:")
  db' <- fmap T.pack <$> lookupEnv "INDEX"
  (serv, nm) <- case db' of
                  Just db -> do c <- PG.connectPostgreSQL $ T.encodeUtf8 $ "dbname='" <> db <> "'"
                                return (SomeIndexServer (PG c), db)
                  Nothing -> do sql <- readFile "migrations/sqlite.sql"
                                c <- SQLITE.open ":memory:"
                                SQLITE.execute_ c (fromString sql)
                                let serv = SomeIndexServer (SL c)
                                log' "Running indexer to populate :memory: index."
                                -- NOTE(dbp 2017-05-29): Run many times because
                                -- we need permanodes in DB before files stored
                                -- in them are indexed
                                index store serv
                                index store serv
                                index store serv
                                return (serv, ":memory:")
  keyid <- T.pack <$> getEnv "KEY"
  keyblob <- getPubKey keyid
  ref <- writeBlob store keyblob
  let key = Key keyid ref
  log' $ "Opening the Shed [Blobs " <> pth <> " Index " <> nm <> "]"
  return (Ctxt defaultFnRequest store serv lib key)

main :: IO ()
main = withStderrLogging $
  do ctxt <- initializer
     runEnv 3000 $ toWAI ctxt site

instance FromParam SHA1 where
  fromParam [x] | "sha1-" `T.isPrefixOf` x = Right $ SHA1 x
  fromParam []  = Left ParamMissing
  fromParam _   = Left ParamTooMany

site :: Ctxt -> IO Response
site ctxt = do
  log' $ T.decodeUtf8 (requestMethod (fst $ _req ctxt)) <> " " <> T.decodeUtf8 (rawPathInfo (fst $ _req ctxt))
  route ctxt [ end // param "page"          ==> indexH
                       , path "static" ==> staticServe "static"
                       , segment // path "thumb" ==> thumbH
                       , segment ==> renderH
                       , path "blob" // segment ==> blobH
                       , path "file" // segment ==> \ctxt sha -> File.serve (_store ctxt) sha
                       , path "raw" // segment ==> rawH
                       , path "upload" // file "file" !=> uploadH
                       , path "search" // param "q" ==> searchH
                       , path "reindex" ==> reindexH
                       , path "wipe" ==> wipeH
                       ]
    `fallthrough` do r <- render ctxt "404"
                     case r of
                       Just r' -> return r'
                       Nothing -> notFoundText "Page not found"

permanodeSubs :: Permanode -> Substitutions
permanodeSubs (Permanode (SHA1 sha) attrs thumb prev) =
  L.subs [("permanodeRef", L.textFill sha)
         ,("contentRef", L.textFill $ attrs M.! "camliContent")
         ,("has-thumbnail", justFill thumb)
         ,("no-thumbnail", nothingFill thumb)
         ,("has-preview", justFill prev)
         ,("preview", L.rawTextFill $ maybe "" (T.replace "\n" "</p><p>" . HE.text) prev)]
  where
    justFill m = if isJust m then L.fillChildren else L.textFill ""
    nothingFill m = if isJust m then L.textFill "" else L.fillChildren

indexH :: Ctxt -> Maybe Int -> IO (Maybe Response)
indexH ctxt page = do
  ps <- getPermanodes (_db ctxt) (fromMaybe 0 page)
  renderWith ctxt
    (L.subs [("has-more", L.fillChildren)
            ,("next-page", L.textFill $ maybe "1" (T.pack . show . (+1)) page)
            ,("permanodes", L.mapSubs permanodeSubs ps)
            ,("q", L.textFill "")])
    "index"

searchH :: Ctxt -> Text -> IO (Maybe Response)
searchH ctxt q = do
  if T.strip q == "" then redirect "/" else do
    ps <- search (_db ctxt) q
    if length ps == 0 then redirect "/" else
      renderWith ctxt
        (L.subs [("has-more", L.textFill "")
                ,("q", L.textFill q)
                ,("permanodes", L.mapSubs permanodeSubs ps)])
        "index"

reindexH :: Ctxt -> IO (Maybe Response)
reindexH ctxt = do
  index (_store ctxt) (_db ctxt)
  okText "OK."

wipeH :: Ctxt -> IO (Maybe Response)
wipeH ctxt = do
  wipe (_db ctxt)
  redirect "/"

mmsum :: (Monad f, MonadPlus m, Foldable t) => t (f (m a)) -> f (m a)
mmsum = foldl (liftA2 mplus) (return mzero)

renderH :: Ctxt -> SHA1 -> IO (Maybe Response)
renderH ctxt sha = do
  res' <- readBlob (_store ctxt) sha
  case res' of
    Nothing  -> return Nothing
    Just bs ->
      liftA2 mplus
      (mmsum $ map (\f -> f (_store ctxt) (_db ctxt) (renderWith ctxt) sha bs)
        [File.toHtml
        ,Email.toHtml
        ])
      (blobH ctxt sha)


blobH :: Ctxt -> SHA1 -> IO (Maybe Response)
blobH ctxt sha = do
  res' <- readBlob (_store ctxt) sha
  case res' of
    Nothing  -> return Nothing
    Just bs ->
      route ctxt [anything ==> \_ -> Permanode.toHtml (_store ctxt) (_db ctxt) (renderWith ctxt) sha bs
                 ,anything ==> \_ -> do
                     m <- magicOpen [MagicMimeType]
                     magicLoadDefault m
                     let b = BL.toStrict bs
                     mime <- unsafeUseAsCStringLen b (magicCString m)
                     let display = renderWith ctxt (L.subs [("content", L.rawTextFill (hyperLinkEscape (T.decodeUtf8 b)))]) "blob"
                     case mime of
                       "text/plain" -> display
                       "text/html"  -> display
                       _            -> rawH ctxt sha]

rawH :: Ctxt -> SHA1 -> IO (Maybe Response)
rawH ctxt sha@(SHA1 s) =
  do res' <- readBlob (_store ctxt) sha
     case res' of
       Nothing  -> return Nothing
       Just res -> return $ Just $ responseLBS status200 [] res

renderIcon :: IO (Maybe Response)
renderIcon = sendFile "static/icon.png"

thumbH :: Ctxt -> SHA1 -> IO (Maybe Response)
thumbH ctxt sha =
  do res <- getThumbnail (_db ctxt) sha
     case res of
       Nothing -> renderIcon
       Just jpg -> return $ Just $ responseBuilder status200 [(hContentType, "image/jpeg")] (Builder.fromByteString jpg)


uploadH :: Ctxt -> File -> IO (Maybe Response)
uploadH ctxt f = do log' $ "Uploading " <> fileName f <> "..."
                    process (_store ctxt) (_db ctxt) (_key ctxt)  f
                    okText "OK"
