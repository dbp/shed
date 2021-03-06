{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
-- This module contains logic pertaining to camliType "file"
module Shed.Blob.File where

import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import           Data.Aeson.Types
import           Data.Binary.Builder      (Builder)
import qualified Data.Binary.Builder      as Builder
import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as B
import qualified Data.ByteString.Lazy     as BL
import           Data.ByteString.Unsafe   (unsafeUseAsCStringLen)
import           Data.Char                (toLower)
import qualified Data.Map                 as M
import           Data.Maybe               (catMaybes)
import           Data.Text                (Text)
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as T
import           Magic                    (MagicFlag (MagicMimeType),
                                           magicCString, magicLoadDefault,
                                           magicOpen)
import           Network.HTTP.Types       (hContentType, status200)
import           Network.Wai              (Response, responseBuilder)
import           System.FilePath          (takeExtension)
import           Web.Fn                   (File (..))
import qualified Web.Larceny              as L

import qualified Shed.Blob.Permanode      as Permanode
import           Shed.BlobServer
import           Shed.Images
import           Shed.IndexServer
import           Shed.Types
import           Shed.Util

data Part = Part SHA1 Int deriving Show

instance FromJSON Part where
  parseJSON (Object v) = Part <$> v .: "blobRef"
                              <*> v .: "size"
  parseJSON invalid = typeMismatch "Part" invalid

instance ToJSON Part where
  toJSON (Part ref size) = object ["blobRef" .= ref
                                  ,"size" .= size]


data FileBlob = FileBlob { fName  :: Text
                         , fParts :: [Part]
                         } deriving Show

instance FromJSON FileBlob where
    parseJSON (Object v) =
      do t <- v .: "camliType"
         if t == ("file" :: Text) then
           FileBlob <$> v .: "fileName"
                    <*> v .: "parts"
           else fail "Not a file"
    parseJSON invalid    = typeMismatch "Blob" invalid


instance ToJSON FileBlob where
  toJSON (FileBlob name parts) =
    object ["camliVersion" .= (1 :: Int)
           ,"camliType" .= ("file" :: Text)
           ,"fileName" .= name
           ,"parts" .= parts]

indexBlob :: SomeBlobServer -> SomeIndexServer -> SHA1 -> FileBlob -> IO ()
indexBlob store serv sha (FileBlob name parts) = do
  exists <- permanodeHasContent serv sha
  when exists $ do
    setPermanodeShowInUI serv sha
    setSearchHigh serv sha name
    builder <- readFileBytes store parts
    let dat = BL.toStrict $ Builder.toLazyByteString builder
    res <- getExifThumbnail dat
    case res of
      Nothing  ->
        do m <- magicOpen [MagicMimeType]
           magicLoadDefault m
           mime <- unsafeUseAsCStringLen dat (magicCString m)
           let mkThumb = do
                thm <- createThumbnail dat
                case thm of
                  Nothing  -> return ()
                  Just jpg ->
                    setPermanodeThumbnail serv sha (BL.toStrict jpg)
           case mime of
             "image/jpeg" -> mkThumb
             "image/png"  -> mkThumb
             _            -> return ()
      Just jpg -> setPermanodeThumbnail serv sha jpg

recognizeBlob :: SomeBlobServer -> SomeIndexServer -> Key -> File -> (File -> IO ()) -> IO ()
recognizeBlob store serv key file recognize =
  case fileContentType file of
    "image/jpeg" -> addFile store serv key file
    "image/png" -> addFile store serv key file
    typ -> case map toLower $ takeExtension (T.unpack $ fileName file) of
             ".jpg"  -> addFile store serv key file
             ".jpeg" -> addFile store serv key file
             ".png"  -> addFile store serv key file
             ext     -> return ()


chunkSize :: Int
chunkSize = 1000000

addChunks :: SomeBlobServer -> ByteString -> IO [(SHA1, Int)]
addChunks store bs = do
  let chunks = splitEvery chunkSize bs
  mapM (\p -> (,B.length p) <$> writeBlob store p) chunks

splitEvery :: Int -> ByteString -> [ByteString]
splitEvery n bs = if B.length bs <= n then [bs] else
  let (f,r) = B.splitAt n bs in f : splitEvery n r

readFileBytes :: BlobServer a => a -> [Part] -> IO Builder
readFileBytes store ps =
  do bs <- catMaybes <$> mapM (\(Part sha _) -> readBlob store sha) ps
     return $ foldl (\builder st ->
               Builder.append builder
               (Builder.fromLazyByteString st))
       Builder.empty
       bs

addFile :: SomeBlobServer -> SomeIndexServer -> Key -> File -> IO ()
addFile store serv key file = do
  refs <- addChunks store (BL.toStrict $ fileContent file)
  let parts = map (uncurry Part) refs
  let fileblob = FileBlob (fileName file) parts
  let fileblob' = BL.toStrict $ encodePretty fileblob
  exists <- statBlob store fileblob'
  if exists then return () else do
    (SHA1 fref) <- writeBlob store fileblob'
    (pref, permablob) <- Permanode.addPermanode store key
    (cref, claimblob) <- Permanode.setAttribute store key pref "camliContent" fref
    Permanode.indexBlob store serv pref permablob
    Permanode.indexBlob store serv cref claimblob
    indexBlob store serv (SHA1 fref) fileblob

toHtml :: SomeBlobServer -> SomeIndexServer -> (L.Substitutions () -> Text -> IO (Maybe Response)) -> SHA1 -> BL.ByteString -> IO (Maybe Response)
toHtml store serv renderWith (SHA1 sha) bs =
  case decode bs of
    Just (FileBlob name ps) -> do
      renderWith (L.subs [("name", L.textFill name)
                         ,("fileRef", L.textFill sha)])
        "file"
    _ -> return Nothing

serve :: SomeBlobServer -> SHA1 -> IO (Maybe Response)
serve store sha = do
  bs <- readBlob store sha
  case decode =<< bs of
    Just (FileBlob name ps) -> do
      let content = maybe [] (\c -> [(hContentType, c)]) $ M.lookup (takeExtension $ T.unpack name) mimeMap
      builder <- readFileBytes store ps
      return $ Just $ responseBuilder status200 content builder
    _ -> return Nothing


-- NOTE(dbp 2015-11-05): This list taken from snap-core, BSD3 licensed.
mimeMap :: M.Map String ByteString
mimeMap =  M.fromList [
  ( ".asc"     , "text/plain"                        ),
  ( ".asf"     , "video/x-ms-asf"                    ),
  ( ".asx"     , "video/x-ms-asf"                    ),
  ( ".avi"     , "video/x-msvideo"                   ),
  ( ".bz2"     , "application/x-bzip"                ),
  ( ".c"       , "text/plain"                        ),
  ( ".class"   , "application/octet-stream"          ),
  ( ".conf"    , "text/plain"                        ),
  ( ".cpp"     , "text/plain"                        ),
  ( ".css"     , "text/css"                          ),
  ( ".cxx"     , "text/plain"                        ),
  ( ".dtd"     , "text/xml"                          ),
  ( ".dvi"     , "application/x-dvi"                 ),
  ( ".gif"     , "image/gif"                         ),
  ( ".gz"      , "application/x-gzip"                ),
  ( ".hs"      , "text/plain"                        ),
  ( ".htm"     , "text/html"                         ),
  ( ".html"    , "text/html"                         ),
  ( ".ico"     , "image/x-icon"                      ),
  ( ".jar"     , "application/x-java-archive"        ),
  ( ".jpeg"    , "image/jpeg"                        ),
  ( ".jpg"     , "image/jpeg"                        ),
  ( ".js"      , "text/javascript"                   ),
  ( ".json"    , "application/json"                  ),
  ( ".log"     , "text/plain"                        ),
  ( ".m3u"     , "audio/x-mpegurl"                   ),
  ( ".mov"     , "video/quicktime"                   ),
  ( ".mp3"     , "audio/mpeg"                        ),
  ( ".mpeg"    , "video/mpeg"                        ),
  ( ".mpg"     , "video/mpeg"                        ),
  ( ".ogg"     , "application/ogg"                   ),
  ( ".pac"     , "application/x-ns-proxy-autoconfig" ),
  ( ".pdf"     , "application/pdf"                   ),
  ( ".png"     , "image/png"                         ),
  ( ".ps"      , "application/postscript"            ),
  ( ".qt"      , "video/quicktime"                   ),
  ( ".sig"     , "application/pgp-signature"         ),
  ( ".spl"     , "application/futuresplash"          ),
  ( ".svg"     , "image/svg+xml"                     ),
  ( ".swf"     , "application/x-shockwave-flash"     ),
  ( ".tar"     , "application/x-tar"                 ),
  ( ".tar.bz2" , "application/x-bzip-compressed-tar" ),
  ( ".tar.gz"  , "application/x-tgz"                 ),
  ( ".tbz"     , "application/x-bzip-compressed-tar" ),
  ( ".text"    , "text/plain"                        ),
  ( ".tgz"     , "application/x-tgz"                 ),
  ( ".torrent" , "application/x-bittorrent"          ),
  ( ".ttf"     , "application/x-font-truetype"       ),
  ( ".txt"     , "text/plain"                        ),
  ( ".wav"     , "audio/x-wav"                       ),
  ( ".wax"     , "audio/x-ms-wax"                    ),
  ( ".wma"     , "audio/x-ms-wma"                    ),
  ( ".wmv"     , "video/x-ms-wmv"                    ),
  ( ".xbm"     , "image/x-xbitmap"                   ),
  ( ".xml"     , "text/xml"                          ),
  ( ".xpm"     , "image/x-xpixmap"                   ),
  ( ".xwd"     , "image/x-xwindowdump"               ),
  ( ".zip"     , "application/zip"                   ) ]
