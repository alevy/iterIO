
module Data.IterIO.ListLike where

import Prelude hiding (null)
import Control.Exception (onException)
import Control.Monad
import Control.Monad.Trans
-- import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Data.Monoid
import Data.Char
-- import Data.Word
import Network.Socket
import System.IO

import qualified Data.ListLike as LL

import Data.IterIO.Base
import Data.IterIO.Extra

echr :: (Enum e) => e -> Char
echr = chr . fromEnum

-- | Turn data into a 'Chunk'.  Set the EOF marker when the data is
-- null.
dataToChunk :: (ChunkData t) => t -> Chunk t
dataToChunk t = Chunk t $ null t

--
-- Iters
--

-- | Like 'lineI', but returns 'Nothing' on EOF.
safeLineI :: (Monad m, LL.ListLike t e, LL.StringLike t, Eq t, Enum e, Eq e) =>
             Iter t m (Maybe t)
safeLineI = IterF $ return . doline LL.empty
    where
      cr = LL.fromString "\r"
      nl = LL.fromString "\n"
      crnl = LL.fromString "\r\n"
      eol c = echr c == '\n' || echr c == '\r'
      doline acc (Chunk t eof) =
          let acc' = LL.append acc t
              (l, r) = LL.break eol acc'
              result = dolr eof l r
          in case result of
               Just (l', r') -> Done (Just l') (Chunk r' eof)
               Nothing | eof -> Done Nothing (Chunk acc' True)
               _             -> IterF $ return . doline acc'
      dolr eof l r
          | LL.isPrefixOf nl r = Just (l, LL.drop (LL.length nl) r)
          | LL.isPrefixOf crnl r = Just (l, LL.drop (LL.length crnl) r)
          | LL.isPrefixOf cr r && (eof || r /= cr) =
              Just (l, LL.drop (LL.length cr) r)
          | otherwise = Nothing

-- | Return a line delimited by \\r, \\n, or \\r\\n.
lineI :: (Monad m, ChunkData t, LL.ListLike t e, LL.StringLike t
         , Eq t, Enum e, Eq e) =>
         Iter t m t
lineI = do
  mline <- safeLineI
  case mline of
    Nothing -> throwEOFI "lineI"
    Just line -> return line

-- | Return a string that is at most the number of bytes specified in
-- the first arguments, and at least one byte unless EOF is
-- encountered, in which case the empty string is returned.
stringMaxI :: (ChunkData t, LL.ListLike t e, Monad m) =>
              Int
           -> Iter t m t
stringMaxI maxlen = IterF $ return . dostring
    where
      dostring (Chunk s eof) =
          if null s && maxlen > 0 && not eof
            then stringMaxI maxlen
            else case LL.splitAt maxlen s of
                   (h, t) -> Done h $ Chunk t eof

-- | Return a sring that is exactly len bytes, unless an EOF is
-- encountered in which case a shorter string is returned.
stringExactI :: (ChunkData t, LL.ListLike t e, Monad m) =>
                Int
             -> Iter t m t
stringExactI len | len <= 0  = return mempty
                 | otherwise = accumulate mempty
    where
      accumulate acc = do
        t <- stringMaxI (len - LL.length acc)
        if null t then return acc else
            let acc' = LL.append acc t
            in if LL.length t == len then return acc' else accumulate acc'

-- | Put byte strings to a file handle then write an EOF to it. 
handleI :: (MonadIO m, ChunkData t, LL.ListLikeIO t e) =>
           Handle
        -> Iter t m ()
handleI h = putI (liftIO . LL.hPutStr h) (liftIO $ hShutdown h 1)

--
--
sockDgramI :: (MonadIO m, SendRecvString t) =>
              Socket
           -> Maybe SockAddr
           -> Iter [t] m ()
sockDgramI s mdest = do
  mpkt <- safeHeadI
  case mpkt of
    Nothing  -> return ()
    Just pkt -> liftIO (genSendTo s pkt mdest) >> sockDgramI s mdest

--
-- EnumOs
--

-- | Read datagrams from a socket and feed a list of strings (one for
-- each datagram) into an Iteratee.
enumDgram :: (MonadIO m, SendRecvString t) =>
             Socket
          -> EnumO [t] m a
enumDgram sock = enumO $ do
  (msg, r, _) <- liftIO $ genRecvFrom sock 0x10000
  return $ if r < 0 then chunkEOF else chunk [msg]


-- | Read datagrams from a socket and feed a list of (Bytestring,
-- SockAddr) pairs (one for each datagram) into an Iteratee.
enumDgramFrom :: (MonadIO m, SendRecvString t) =>
                 Socket
              -> EnumO [(t, SockAddr)] m a
enumDgramFrom sock = enumO $ do
  (msg, r, addr) <- liftIO $ genRecvFrom sock 0x10000
  return $ if r < 0 then chunkEOF else chunk [(msg, addr)]

-- | Feed data from a file handle into an 'Iter' in Lazy
-- 'L.ByteString' format.
enumHandle' :: (MonadIO m) => Handle -> EnumO L.ByteString m a
enumHandle' = enumHandle'

-- | Like 'enumHandle'', but can use any 'LL.ListLikeIO' type for the
-- data instead of just 'L.ByteString'.
enumHandle :: (MonadIO m, ChunkData t, LL.ListLikeIO t e) =>
               Handle
            -> EnumO t m a
enumHandle h = enumO $ do
  liftIO $ hWaitForInput h (-1)
  buf <- liftIO $ LL.hGetNonBlocking h defaultChunkSize
  return $ dataToChunk buf

-- | Enumerate the contents of a file as a series of lazy
-- 'L.ByteString's.
enumFile' :: (MonadIO m) => FilePath -> EnumO L.ByteString m a
enumFile' = enumFile'

-- | Like 'enumFile'', but can use any 'LL.ListLikeIO' type for the
-- data read from the file.
enumFile :: (MonadIO m, ChunkData t, LL.ListLikeIO t e) =>
             FilePath
          -> EnumO t m a
enumFile path =
    enumObracket (liftIO $ openFile path ReadMode) (liftIO . hClose) $
        \h -> liftIO (LL.hGet h defaultChunkSize) >>= return . dataToChunk


--
-- EnumIs
--

-- | This inner enumerator is like 'inumNop' in that it passes
-- unmodified 'Chunk's straight through to an iteratee.  However, it
-- also logs the 'Chunk's to a file (which can optionally be trucated
-- or appended to, based on the second argument).
inumLog :: (MonadIO m, ChunkData t, LL.ListLikeIO t e) =>
           FilePath             -- ^ Path to log to
        -> Bool                 -- ^ True to truncate file
        -> EnumI t t m a
inumLog path trunc iter = do
  h <- liftIO $ openFile path (if trunc then WriteMode else AppendMode)
  liftIO $ hSetBuffering h NoBuffering
  inumhLog h iter

-- | Like 'inumLog', but takes a writeable file handle rather than a
-- file name.  Closes the handle when done.
inumhLog :: (MonadIO m, ChunkData t, LL.ListLikeIO t e) =>
            Handle
         -> EnumI t t m a
inumhLog h =
    enumI $ do
      c@(Chunk buf eof) <- chunkI
      liftIO $ do
              unless (null buf) $ LL.hPutStr h buf `onException` hClose h
              when eof $ hClose h
      return c
