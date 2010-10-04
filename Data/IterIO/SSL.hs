module Data.IterIO.SSL where

import qualified Data.ByteString.Lazy as L
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Control.Concurrent
import Control.Exception (throwIO, ErrorCall(..))
import Control.Monad
import Control.Monad.Trans
import qualified Network.Socket as Net
import qualified OpenSSL.Session as SSL
import System.Cmd
import System.Exit

import Data.IterIO.Base
import Data.IterIO.Inum

-- | Simple OpenSSL 'Onum'.
enumSsl :: (MonadIO m) => SSL.SSL -> Onum L.ByteString m a
enumSsl ssl = mkInumM $ irepeat $
              liftIO (SSL.read ssl defaultChunkSize) >>=
                     ifeed1 . L.fromChunks . (: [])

-- | Simple OpenSSL 'Iter'.  Does not do any kind of shutdown.
sslI :: (MonadIO m) => SSL.SSL -> Iter L.ByteString m ()
sslI ssl = loop
    where loop = do
            Chunk t eof <- chunkI
            unless (L.null t) $ liftIO $ SSL.lazyWrite ssl t
            if eof then return () else loop

-- | Turn a socket into an 'Iter' and 'Onum' that use OpenSSL to read
-- and write from the socket, respectively.  Don't forget to call this
-- from within 'SSL.withOpenSSL'.
sslFromSocket :: (MonadIO m) =>
                 SSL.SSLContext
              -- ^ OpenSSL context
              -> Net.Socket
              -- ^ The socket
              -> Bool
              -- ^ 'True' for server handshake, 'False' for client
              -> IO (Iter L.ByteString m (), Onum L.ByteString m a)
sslFromSocket ctx sock server = do
  mn <- newMVar (2 :: Int)
  ssl <- SSL.connection ctx sock
  if server then SSL.accept ssl else SSL.connect ssl
  let cleanW = liftIO $ modifyMVar mn $ \n -> do
               if (n < 2)
                 then do SSL.shutdown ssl SSL.Bidirectional
                         Net.sClose sock
                 else SSL.shutdown ssl SSL.Unidirectional
               return (n - 1, ())
      cleanR = mkInumM $ liftIO $ modifyMVar mn $ \n -> do
               when (n < 2) $ do SSL.shutdown ssl SSL.Bidirectional
                                 Net.sClose sock
               return (n - 1, ())
  return (sslI ssl >> cleanW, enumSsl ssl `cat` cleanR)

-- | Simplest possible SSL context, loads cert and unencrypted private
-- key from a single file.
simpleContext :: FilePath -> IO SSL.SSLContext
simpleContext keyfile = do
  ctx <- SSL.context
  SSL.contextSetDefaultCiphers ctx
  SSL.contextSetCertificateFile ctx keyfile
  SSL.contextSetPrivateKeyFile ctx keyfile
  SSL.contextSetVerificationMode ctx $ SSL.VerifyPeer False True
  return ctx

-- | Quick and dirty funciton to generate a self signed certificate
-- for testing and stick it in a file.  E.g.:
--
-- > genSelfSigned "testkey.pem" "localhost"
genSelfSigned :: FilePath       -- ^ Filename in which to output key
              -> String         -- ^ Common Name (usually domain name)
              -> IO ()
genSelfSigned file cn = do
  r <- rawSystem "openssl"
       [ "req", "-x509", "-nodes", "-days", "365", "-subj", "/CN=" ++ cn
       , "-newkey", "rsa:1024", "-keyout", file, "-out", file
       ]
  when (r /= ExitSuccess) $ throwIO $ ErrorCall "openssl failed"