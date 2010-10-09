
module Main where

-- import Control.Monad.Trans
import Control.Concurrent
import Control.Exception (finally)
-- import Control.Monad.Trans
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Network.Socket as Net
import qualified OpenSSL as SSL
import qualified OpenSSL.Session as SSL
import System.IO
-- import Text.XHtml.Strict

import Data.IterIO
-- import Data.IterIO.Parse
import Data.IterIO.Http
import Data.IterIO.SSL
-- import Data.IterIO.ListLike

type L = L.ByteString

port :: Net.PortNumber
-- port = 4443
port = 8000

myListen :: Net.PortNumber -> IO Net.Socket
myListen pn = do
  sock <- Net.socket Net.AF_INET Net.Stream Net.defaultProtocol
  Net.setSocketOption sock Net.ReuseAddr 1
  Net.bindSocket sock (Net.SockAddrInet pn Net.iNADDR_ANY)
  Net.listen sock Net.maxListenQueue
  return sock

handle_connection :: Onum L IO (Iter L IO HttpReq) -> Iter L IO () -> IO ()
handle_connection enum _iter = do
  req <- enum |. inumLog "http.log" True |$ httpreqI
  print req

accept_loop :: SSL.SSLContext -> QSem -> Net.Socket -> IO ()
accept_loop ctx sem sock = do
  (s, addr) <- Net.accept sock
  print addr
  -- (iter, enum) <- liftIO $ sslFromSocket ctx s True
--  _ <- forkIO $ handle_connection (enum |. inumStderr) (inumStderr .| iter)
  h <- Net.socketToHandle s ReadWriteMode
  handle_connection (enumHandle h |. inumStderr) (handleI h) `finally` hClose h
-- _ <- forkIO $ handle_connection (enumHandle h) (handleI h) `finally` hClose h
  accept_loop ctx sem sock

main :: IO ()
main = Net.withSocketsDo $ SSL.withOpenSSL $ do
         sock <- myListen port
         sem <- newQSem 0
         ctx <- simpleContext "testkey.pem"
         accept_loop ctx sem sock
         waitQSem sem
         Net.sClose sock

