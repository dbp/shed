{-# LANGUAGE OverloadedStrings #-}
module Shed.BlobServer.Directory where

import qualified Crypto.Hash.SHA1        as SHA1
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy    as BL
import           Data.Monoid
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as T
import           System.Directory        (createDirectoryIfMissing,
                                          doesFileExist, listDirectory)

import           Shed.BlobServer
import           Shed.Types

data FileStore = FileStore Text

getDir :: Text -> Text -> FilePath
getDir dir name = T.unpack $ dir <> "/sha1/" <> T.take 2 (T.drop 5 name) <> "/" <> T.take 2 (T.drop 7 name) <> "/"

instance BlobServer FileStore where
 writeBlob (FileStore dir) dat = do
   (SHA1 name) <- getBlobName dat
   let holder = getDir dir name
   createDirectoryIfMissing True holder
   let filename = holder <> T.unpack name <> ".dat"
   BS.writeFile filename dat
   return (SHA1 name)

 readBlob (FileStore dir) (SHA1 t) = if not ("sha1-" `T.isPrefixOf` t) then error $ T.unpack $ "SHA1 does not start with 'sha1-': " <> t else
  do let filename = getDir dir t <> T.unpack t <> ".dat"
     ex <- doesFileExist filename
     if ex
       then Just <$> BL.readFile filename
       else return Nothing

 enumerateBlobs (FileStore dir) f = enum [dir <> "/sha1"] 0
  where
    enum :: [Text] -> Int -> IO ()
    enum pth 3 =
      do dat <- BL.readFile $ T.unpack $ T.intercalate "/" pth
         f (SHA1 $ T.takeWhile (/= '.') (last pth)) dat
    enum pth n = do fs <- listDirectory $ T.unpack $ T.intercalate "/" pth
                    mapM_ (\f -> enum (pth <> [T.pack f]) (n+1)) fs
