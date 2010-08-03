{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}


{-   Alternate Enumerator/Iteratee take by David Mazieres.

     An iteratee is a data sink that is fed chunks of data.  It may
     return a useful result, or its use may like in the side-effects
     it has, such as storing the data to a file.  Iteratees are
     represented by the type @'Iter' t m a@.  @t@ is the type of the
     data chunks (which must be a 'ChunkData', such as 'String' or
     lazy 'L.ByteString').  @m@ is the 'Monad' in which the iteratee
     runs--for instance 'IO' (or an instance of 'MonadIO') for the
     iteratee to perform IO.  @a@ is the result type of the iteratee,
     for when it has consumed enough input to produce a result.

     An Enumerator is a data source that feeds data chunks to an
     iteratee.  There are two types of Enumerator.

       * An /outer enumerator/, represented by the type 'EnumO',
         generates data from some external source, such as IO (or
         potentially some internal state such as a somepseudo-random
         generator).  Outer enumerators are generally constructed
         using 'enumO', which repeatedly runs a computation that
         generates chunks of data.  When the enumerator is out of
         data, data generating computation returns an EOF chunk, and
         'enumO' returns the iteratee so that it can potentially be
         passed to a different enumerator for more data.  (An
         enumerator should not feed 'EOF' to an iteratee--only the
         '|$' operator, 'run', and 'runI' functions do this.)  If the
         iteratee returns a result or fails, the enumerator also
         returns it immediately.

       * An /inner enumerator/, represented by the type 'EnumI', gets
         its data from another enumerator, then feeds this to an
         iteratee.  Thus, an 'EnumI' behaves as an iteratee when
         interfacing to the outer enumerator, and behaves as an
         enumerator when feeding data to some \"inner\" iteratee.
         Inner are build using the function 'enumI', which is
         analogous to 'enumO' for outer enumerators, except that the
         chunk generating computation can use iteratees to process
         data from the outer enumerator.  An inner enumerator, when
         done, returns the inner iteratee's state, as well as its own
         Iteratee state.  An inner enumerator that receives EOF should
         /not/ feed the EOF to its iteratee, as the iteratee may
         subsequently be passed to another enumerator for more input.
         (This is convention is respected by the 'enumI' function.)

    IO is performed by applying an outer enumerator to an iteratee,
    using the '|$' (\"pipe apply\") binary operator.

    An important property of enumerators and iteratees is that they
    can be /fused/.  The '|..' operator fuses an outer enumerator with
    an inner enumerator, yielding an outer enumerator, e.g.,
    @enumo '|..' enumi@.  Similarly, the '..|' operator fuses an inner
    enumerator with an iteratee to yield another iteratee, e.g.,
    @enumi '..|' iter@.  Finally, two inner enumerators may be fused
    into one with the '..|..' operator.

    Enumerators may also be concatenated.  Two outer enumerators may
    be concatenated using the 'cat' function.  Thus,
    @enumO1 ``cat`` enumO2@ produces an outer enumerator whose effect
    is to feed first @enumO1@'s data then @enumO2@'s data to an
    iteratee.  Inner enumerators may similarly be concatenated using
    the 'catI' function.

-}

-- | Enumerator/Iteratee IO abstractions.  See the documentation for
-- "Data.IterIO" for a high-level overview of these abstractions.
module Data.IterIO.Base
    (-- * Base types
     ChunkData(..), Chunk(..), Iter(..), EnumO, EnumI, Codec, CodecR(..)
    -- * Core functions
    , (|$)
    , runIter, run
    , chunk, chunkEOF, isChunkEOF
    -- * Concatenation functions
    , cat, catI
    -- * Fusing operators
    , (|..), (..|..), (..|)
    -- * Enumerator construction functions
    , chunkerToCodec, iterToCodec
    , enumO, enumO', enumObracket, enumI, enumI'
    -- * Exception and error functions
    , IterNoParse(..), IterEOF(..), IterExpected(..), IterParseErr(..)
    , isIterError, isEnumError
    , throwI, throwEOFI, expectedI
    , tryI, tryBI, catchI, catchBI, handlerI, handlerBI
    , resumeI, verboseResumeI, mapExceptionI
    -- * Other functions
    , iterLoop
    , ifParse, ifNoParse, multiParse
    -- , fixIterPure, fixMonadIO
    -- * Some basic Iteratees
    , nullI, dataI, chunkI
    , wrapI, runI, joinI, returnI
    , headI, safeHeadI
    , putI, sendI
    -- * Some basic Enumerators
    , enumPure
    , enumCatch, enumHandler, inumCatch
    , inumNop, inumSplit
    ) where

import Prelude hiding (null)
import qualified Prelude
import Control.Applicative (Applicative(..))
import Control.Concurrent.MVar
import Control.Exception (SomeException(..), ErrorCall(..), Exception(..)
                         , try, throw)
import Control.Monad
import Control.Monad.Fix
import Control.Monad.Trans
import Data.IORef
import Data.List (intercalate)
import Data.Monoid
import Data.Typeable
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import System.Environment
import System.IO
import System.IO.Error (mkIOError, eofErrorType, isEOFError)
import System.IO.Unsafe


--
-- Iteratee types
--

-- | @ChunkData@ is the class of data types that can be output by an
-- enumerator and iterated on with an iteratee.  A @ChunkData@ type
-- must be a 'Monoid', but must additionally provide a predicate,
-- @null@, for testing whether an object is equal to 'mempty'.
-- Feeding a @null@ chunk to an iteratee followed by any other chunk
-- should have the same effect as just feeding the second chunk,
-- except that some or all of the effects may happen at the time the
-- iteratee receives the @null@ chunk, which is why sometimes the
-- library explicitly feeds @null@ chunks to iteratees.
class (Monoid t) => ChunkData t where
    null :: t -> Bool
instance ChunkData [a] where
    null = Prelude.null
instance ChunkData L.ByteString where
    null = L.null
instance ChunkData S.ByteString where
    null = S.null
instance ChunkData () where
    null _ = True

-- | @Chunk@ is a wrapper around a 'ChunkData' type that also includes
-- an EOF flag that is 'True' if the data is followed by an
-- end-of-file condition.  An iteratee that receives a @Chunk@ with
-- EOF 'True' must return a result (or failure); it is an error to
-- demand more data after an EOF.
data Chunk t = Chunk t Bool deriving (Eq)

instance (Show t) => Show (Chunk t) where
    showsPrec _ (Chunk t eof) rest =
        "Chunk " ++ show t ++ if eof then "+EOF" ++ rest else rest

-- | Constructor function that builds a chunk containing data and a
-- 'False' EOF flag.
chunk :: t -> Chunk t
chunk t = Chunk t False

-- | An empty chunk with the EOF flag 'True'.
chunkEOF :: (Monoid t) => Chunk t
chunkEOF = Chunk mempty True

-- | Returns True if a chunk is the result of 'chunkEOF' (i.e., has no
-- data and a 'True' EOF bit).
isChunkEOF :: (ChunkData t) => Chunk t -> Bool
isChunkEOF (Chunk t eof) = eof && null t

instance (ChunkData t) => Monoid (Chunk t) where
    mempty = Chunk mempty False
    mappend (Chunk a False) (Chunk b eof) = Chunk (mappend a b) eof
    mappend a (Chunk b True) | null b     = a
    mappend _ _                           = error "mappend to EOF"

instance (ChunkData t) => ChunkData (Chunk t) where
    null (Chunk t False) = null t
    null (Chunk _ True)  = False

-- | Generalized class of errors that occur when an Iteratee does not
-- receive expected input.  (Catches 'IterEOF', 'IterExpected', and
-- the miscellaneous 'IterParseErr'.)
data IterNoParse = forall a. (Exception a) => IterNoParse a deriving (Typeable)
instance Show IterNoParse where
    showsPrec _ (IterNoParse e) rest = show e ++ rest
instance Exception IterNoParse

noParseFromException :: (Exception e) => SomeException -> Maybe e
noParseFromException s = do IterNoParse e <- fromException s; cast e

noParseToException :: (Exception e) => e -> SomeException
noParseToException = toException . IterNoParse

-- | End-of-file occured in an Iteratee that required more input.
data IterEOF = IterEOF IOError deriving (Typeable)
instance Show IterEOF where
    showsPrec _ (IterEOF e) rest = show e ++ rest
instance Exception IterEOF where
    toException = noParseToException
    fromException = noParseFromException

unIterEOF :: SomeException -> SomeException
unIterEOF e = case fromException e of
                Just (IterEOF e') -> toException e'
                _                 -> e

-- | Iteratee expected particular input and did not receive it.
data IterExpected = IterExpected [String] deriving (Typeable)
instance Show IterExpected where
    showsPrec _ (IterExpected [token]) rest =
        "Iteratee expected " ++ token ++ rest
    showsPrec _ (IterExpected tokens) rest =
        "Iteratee expected one of ["
        ++ intercalate ", " tokens ++ "]" ++ rest
instance Exception IterExpected where
    toException = noParseToException
    fromException = noParseFromException

-- | Miscellaneous Iteratee parse error.
data IterParseErr = IterParseErr String deriving (Typeable)
instance Show IterParseErr where
    showsPrec _ (IterParseErr err) rest =
        "Iteratee parse error: " ++ err ++ rest
instance Exception IterParseErr where
    toException = noParseToException
    fromException = noParseFromException


-- | The basic Iteratee type is @Iter t m a@, where @t@ is the type of
-- input (in class 'ChunkData'), @m@ is a monad in which the iteratee
-- may execute actions (using the monad transformer 'lift' method),
-- and @a@ is the result type of the iteratee.
--
-- An @Iter@ is in one of three states:  it may require more input, it
-- may have produced a result, or it may have failed.  The first case
-- is signaled by the 'IterF' constructor, which contains a function
-- from a 'Chunk' of data to a new state of the iteratee (in monad
-- @m@).  The second case is signaled by the 'Done' constructor, which
-- returns both a result of type @a@, and a 'Chunk' containing any
-- residual input the iteratee did not consume.  Finally, failure is
-- signaled by either 'IterFail', 'EnumOFail', or 'EnumIFail',
-- depending on whether the failure occured in an iteratee, an outer
-- enumerator, or an inner enumerator.  (In the last two cases, when
-- an enumerator failed, the result also includes the state of the
-- iteratee, which usually has not failed.)
--
-- Note that @Iter t@ is a 'MonadTrans' and @Iter t m@ is a a 'Monad'
-- (as discussed in the documentation for module "Data.IterIO").
data Iter t m a = IterF (Chunk t -> m (Iter t m a))
                -- ^ The iteratee requires more input.
                | Done a (Chunk t)
                -- ^ Sufficient input was received; the iteratee is
                -- returning a result (of type @a@) and a 'Chunk'
                -- containing any unused input.
                | IterFail SomeException
                -- ^ The iteratee failed.
                | EnumOFail SomeException (Iter t m a)
                -- ^ An 'EnumO' failed; the result includes the status
                -- of the iteratee at the time the enumerator failed.
                | EnumIFail SomeException a
                -- ^ An 'EnumI' failed; this result includes status of
                -- the Iteratee.  (The type @a@ will always be
                -- @'Iter' t m a\'@ for some @a'@ in the result of an
                -- 'EnumI'.)

instance (ChunkData t) => Show (Iter t m a) where
    showsPrec _ (IterF _) rest = "IterF _" ++ rest
    showsPrec _ (Done _ (Chunk t eof)) rest =
        "Done _ (Chunk " ++ (if null t then "mempty " else "_ ")
                         ++ show eof ++ ")" ++ rest
    showsPrec _ (IterFail e) rest = "IterFail " ++ show e ++ rest
    showsPrec _ (EnumOFail e i) rest =
        "EnumOFail " ++ show e ++ " (" ++ (shows i $ ")" ++ rest)
    showsPrec _ (EnumIFail e _) rest =
        "EnumIFail " ++ show e ++ " _" ++ rest

{-
instance (Show t, Show a) => Show (Iter t m a) where
    showsPrec _ (IterF _) rest = "IterF" ++ rest
    showsPrec _ (Done a c) rest = "Done (" ++ show a ++ ") " ++ show c ++ rest
    showsPrec _ (IterFail e) rest = "IterFail " ++ show e ++ rest
    showsPrec _ (EnumOFail e i) rest =
        "EnumOFail " ++ show e ++ " (" ++ (shows i $ ")" ++ rest)
    showsPrec _ (EnumIFail e i) rest =
        "EnumIFail " ++ show e ++ " (" ++ (shows i $ ")" ++ rest)
-}

-- | Runs an 'Iter' on a 'Chunk' of data.  When the 'Iter' is
-- already 'Done', or in some error condition, simulates the behavior
-- appropriately.
--
-- Note that this function asserts the following invariants on the
-- behavior of an 'Iter':
--
--     1. An 'Iter' may not return an 'IterF' (asking for more input)
--        if it received a 'Chunk' with the EOF bit 'True'.
--
--     2. An 'Iter' returning 'Done' must not set the EOF bit if it
--        did not receive the EOF bit.
--
-- It /is/, however, okay for an 'Iter' to return 'Done' without the
-- EOF bit even if the EOF bit was set on its input chunk, as
-- @runIter@ will just propagate the EOF bit.  For instance, the
-- following code is valid:
--
-- @
--      runIter (return ()) 'chunkEOF'
-- @
--
-- Even though it is equivalent to:
--
-- @
--      runIter ('Done' () ('Chunk' 'mempty' True)) ('Chunk' 'mempty' False)
-- @
--
-- in which the first argument to @runIter@ appears to be discarding
-- the EOF bit from the input chunk.  @runIter@ will propagate the EOF
-- bit, making the above code equivalent to to @'Done' () 'chunkEOF'@.
--
-- On the other hand, the following code is illegal, as it violates
-- invariant 2 above:
--
-- @
--      runIter ('Done' () 'chunkEOF') $ 'Chunk' \"some data\" False -- Bad
-- @
runIter :: (ChunkData t, Monad m) =>
           Iter t m a
        -> Chunk t
        -> m (Iter t m a)
runIter (IterF f) c@(Chunk _ eof) = f c >>= setEOF
    where
      setEOF :: (Monad m) => Iter t m a -> m (Iter t m a)
      setEOF (Done a (Chunk t _)) | eof = return $ Done a $ Chunk t eof
      setEOF (Done _ (Chunk _ True)) = error "runIter: IterF returned bogus EOF"
      setEOF (IterF _) | eof = error "runIter: IterF returned after EOF"
      setEOF iter = return iter
runIter (Done a c) c' = return $ Done a (mappend c c')
runIter err _         = return err

instance (ChunkData t, Monad m) => Functor (Iter t m) where
    fmap = liftM

instance (ChunkData t, Monad m) => Applicative (Iter t m) where
    pure   = return
    (<*>)  = ap
    (*>)   = (>>)
    a <* b = do r <- a; _ <- b; return r

instance (ChunkData t, Monad m) => Monad (Iter t m) where
    return a = Done a mempty
    -- Could get rid of ChunkData requirement with the next definition
    -- return a = IterF $ \c -> return $ Done a c
    m >>= k  = IterF $ \c ->
               do m' <- runIter m c
                  case m' of
                    IterF _   -> return $ m' >>= k
                    Done a c' -> runIter (k a) c'
                    _         -> return $ IterFail $ getIterError m'
    fail msg = IterFail $ mkError msg
    -- fail msg = IterFail (toException (IterError msg))

{-
instance (ChunkData t, Monad m) => MonadPlus (Iter t m) where
    mzero = throwI $ IterParseErr "mzero"
    mplus a b = ifParse a return b
-}

getIterError                 :: Iter t m a -> SomeException
getIterError (IterFail e)    = e
getIterError (EnumOFail e _) = e
getIterError (EnumIFail e _) = e
getIterError _               = error "getIterError: no error to extract"

-- | True if an iteratee /or/ an enclosing enumerator has experienced
-- a failure.  (@isIterError@ is always 'True' when 'isEnumError' is
-- 'True', but the converse is not true.)
isIterError :: Iter t m a -> Bool
isIterError (IterF _)       = False
isIterError (Done _ _)      = False
isIterError _               = True

-- | True if an enumerator enclosing an iteratee has experienced a
-- failure (but not if the iteratee itself failed).
isEnumError :: Iter t m a -> Bool
isEnumError (EnumOFail _ _) = True
isEnumError (EnumIFail _ _) = True
isEnumError _               = False

-- | True if an iteratee is in an error state caused by an EOF exception.
isIterEOFError :: Iter t m a -> Bool
isIterEOFError (IterF _) = False
isIterEOFError (Done _ _) = False
isIterEOFError err = case fromException $ getIterError err of
                       Just (IterEOF _) -> True
                       _                -> False

-- | True if an iteratee is in the 'IterF' state (and hence can
-- process more input).
isIterF :: Iter t m a -> Bool
isIterF (IterF _) = True
isIterF _         = False

mkError :: String -> SomeException
mkError msg = toException $ ErrorCall msg

{- fixIterPure and fixIterIO allow MonadFix instances, which support
   out-of-order name bindings in an "mdo" block, provided your file
   has {-# LANGUAGE RecursiveDo #-} at the top.  A contrived example
   would be:

fixtest :: IO Int
fixtest = enumPure [10] `cat` enumPure [1] |$ fixee
    where
      fixee :: Iter [Int] IO Int
      fixee = mdo
        liftIO $ putStrLn "test #1"
        c <- return $ a + b
        liftIO $ putStrLn "test #2"
        a <- headI
        liftIO $ putStrLn "test #3"
        b <- headI
        liftIO $ putStrLn "test #4"
        return c

-- A very convoluted way of computing factorial
fixtest2 :: Int -> IO Int
fixtest2 i = do
  f <- enumPure [2] `cat` enumPure [1] |$ mfix fact
  run $ f i
    where
      fact :: (Int -> Iter [Int] IO Int)
           -> Iter [Int] IO (Int -> Iter [Int] IO Int)
      fact f = do
               ignore <- headI
               liftIO $ putStrLn $ "ignoring " ++ show ignore
               base <- headI
               liftIO $ putStrLn $ "base is " ++ show base
               return $ \n -> if n <=  0
                              then return base
                              else liftM (n *) (f $ n - 1)
-}

{-
-- | This is a fixed point combinator for iteratees over monads that
-- have no side effects.  If you wish to use @mdo@ with such a monad,
-- you can define an instance of 'MonadFix' in which
-- @'mfix' = fixIterPure@.  However, be warned that this /only/ works
-- when computations in the monad have no side effects, as
-- @fixIterPure@ will repeatedly re-invoke the function passsed in
-- when more input is required (thereby also repeating side-effects).
-- For cases in which the monad may have side effects, if the monad is
-- in the 'MonadIO' class then there is already an 'mfix' instance
-- defined using 'fixMonadIO'.
fixIterPure :: (ChunkData t, MonadFix m) =>
               (a -> Iter t m a) -> Iter t m a
fixIterPure f' = dofix mempty f'
    where
      dofix c0 f = IterF $ \c1 -> do
         let c = mappend c0 c1
         iter <- mfix $ \ ~(Done a _) -> runIter (f a) c
         case iter of
           IterF _ -> return $ dofix c f -- Warning: repeats side effects
           _       -> return iter
-}

-- | This is a generalization of 'fixIO' for arbitrary members of the
-- 'MonadIO' class.  
fixMonadIO :: (MonadIO m) =>
              (a -> m a) -> m a
fixMonadIO f = do
  ref <- liftIO $ newIORef $ throw $ mkError "fixMonadIO: non-termination"
  a <- liftIO $ unsafeInterleaveIO $ readIORef ref
  r <- f a
  liftIO $ writeIORef ref r
  return r

instance (ChunkData t, MonadIO m) => MonadFix (Iter t m) where
    mfix f = fixMonadIO f

instance MonadTrans (Iter t) where
    lift m = IterF $ \c -> m >>= return . flip Done c

-- | Lift an IO operation into an 'Iter' monad, but if the IO
-- operation throws an error, catch the exception and return it as a
-- failure of the Iteratee.  An IO exception satisfying the
-- 'isEOFError' predicate is re-wrapped in an 'IterEOF' type so as to
-- be caught by handlers expecting 'IterNoParse'.
instance (ChunkData t, MonadIO m) => MonadIO (Iter t m) where
    liftIO m = do
      result <- lift $ liftIO $ try m
      case result of
        Right ok -> return ok
        Left err -> IterFail $ case fromException err of
                                 Just ioerr | isEOFError ioerr ->
                                                toException $ IterEOF ioerr
                                 _ -> err


-- | Return the result of an iteratee.  If it is still in the 'IterF'
-- state, feed it an EOF to extract a result.  Throws an exception if
-- there has been a failure.
run :: (ChunkData t, Monad m) => Iter t m a -> m a
run iter@(IterF _)  = runIter iter chunkEOF >>= run
run (Done a _)      = return a
run (IterFail e)    = throw $ unIterEOF e
run (EnumOFail e _) = throw $ unIterEOF e
run (EnumIFail e _) = throw $ unIterEOF e


--
-- Exceptions
--

-- | Run an Iteratee, and if it throws a parse error by calling
-- 'expectedI', then combine the exptected tokens with those of a
-- previous parse error.
combineExpected :: (ChunkData t, Monad m) =>
                   IterNoParse
                -- ^ Previous parse error
                -> Iter t m a
                -- ^ Iteratee to run and, if it fails, combine with
                -- previous error
                -> Iter t m a
combineExpected (IterNoParse e) iter =
    case cast e of
      Just (IterExpected e1) -> mapExceptionI (combine e1) iter
      _                      -> iter
    where
      combine e1 (IterExpected e2) = IterExpected $ e1 ++ e2

-- | Try two Iteratees and return the result of executing the second
-- if the first one throws an 'IterNoParse' exception.  The statement
-- @multiParse (a >>= f) b@ is somewhat similar to
-- @'ifParse' a f b@, but the two functions operate differently.
-- Depending on the situation, only one of the two
-- formulations is correct.  Specifically:
-- 
--  * @'ifParse' a f b@ works by first executing @a@, saving a copy of
--    all input consumed by @a@.  If @a@ throws a parse error, the
--    saved input is used to backtrack and execute @b@ on the same
--    input that @a@ just rejected.  If @a@ suceeds, @b@ is never run,
--    @a@'s result is fed to @f@, and the resulting action is executed
--    without backtracking (so any error thrown within @f@ will not be
--    caught by this 'ifParse' expression).
--
--    The main restriction of 'ifParse' is that @a@ must not consume
--    unbounded amounts of input, or the program may exhaust memory
--    saving the input for backtracking.  Note that the second
--    argument to 'ifParse' (in this case 'return') is a continuation
--    for @a@ when @a@ succeeds.
--
--  * @multiParse (a >>= f) b@ avoids the unbounded input problem by
--    executing both @(a >>= f)@ and @b@ concurrently on input chunks
--    as they arrive.  If @a@ throws a parse error, then the result of
--    executing @b@ is returned.  If @a@ either succeeds or throws an
--    exception not of class 'IterNoParse', then the result of running
--    @a@ is returned.  However, in this case, even though @a@'s
--    result is returned, @b@ may have been fed some of the input
--    data.  (Specifically, @b@ will be fed all but the last chunk
--    processed by @a@.)
--
--    The main restriction on @multiParse@ is that the second
--    argument, @b@, must not have monadic side effects.  Otherwise,
--    the result of executing @b@ on some partial input when @a@
--    succeeds can leave the process in an inconsistent state.
--
-- The big advantage of @multiParse@ is that it can avoid storing
-- unbounded amounts of input for backtracking purposes.  Another
-- advantage is that sometimes it is not convenient to break the parse
-- target into an action to execute with backtracking (@a@) and a
-- continuation to execute without (@f@).  @multiParse@ avoids the
-- need to do this, since it does not do backtracking.
--
-- However, it is important to note that it is still possible to end
-- up storing unbounded amounts with @multiParse@.  For example,
-- consider the following code:
--
-- > total :: (Monad m) => Iter String m Int
-- > total = multiParse parseAndSumIntegerList (return -1) -- Bad
--
-- Here the intent is for @parseAndSumIntegerList@ to parse a
-- (possibly huge) list of integers and return their sum.  If there is
-- a parse error at any point in the input, then the result is
-- identical to having defined @total = return -1@.  But @return -1@
-- succeeds immediately, consuming no input, which means that @total@
-- must return all left-over input for the next monad (i.e., @next@ in
-- @total >>= next@).  Since @total@ has to look arbitrarily far into
-- the input to determine that @parseAndSumIntegerList@ fails, in
-- practice @total@ will have to save all input until it knows that
-- @parseAndSumIntegerList@ suceeds.
--
-- A better approach might be:
--
-- @
--   total = multiParse parseAndSumIntegerList ('nullI' >> return -1)
-- @
--
-- Here 'nullI' discards all input until an EOF is encountered, so
-- there is no need to keep a copy of the input around.  This makes
-- sense so long as @total@ is the last or only Iteratee run on the
-- input stream.  (Otherwise, 'nullI' would have to be replaced with
-- an Iteratee that discards input up to some end-of-list marker.)
--
-- Another approach might be to avoid parsing combinators entirely and
-- use:
--
-- @
--   total = parseAndSumIntegerList ``catchI`` handler
--       where handler \('IterNoParse' _) _ = return -1
-- @
--
-- This last definition of @total@ may leave the input in some
-- partially consumed state (including input beyond the parse error
-- that just happened to be in the chunk that caused the parse error).
-- But this is fine so long as @total@ is the last Iteratee executed
-- on the input stream.
multiParse :: (ChunkData t, Monad m) =>
              Iter t m a -> Iter t m a -> Iter t m a
multiParse a@(IterF _) b =
    IterF $ \c -> do
      a1 <- runIter a c
      case a1 of
        Done _ _ -> return a1
        IterF _  -> runIter b c >>= return . multiParse a1
        _        -> case fromException $ getIterError a1 of
                      Just e  -> runIter b c >>= return . combineExpected e
                      Nothing -> return a1
multiParse a b = a `catchI` \err _ -> combineExpected err b

-- | @ifParse iter success failure@ runs @iter@, but saves a copy of
-- all input consumed using 'tryBI'.  (This means @iter@ must not
-- consume unbounded amounts of input!  See 'multiParse' for such
-- cases.)  If @iter@ suceeds, its result is passed to the function
-- @success@.  If @iter@ throws an exception of type 'IterNoParse',
-- then @failure@ is executed with the input re-wound (so that
-- @failure@ is fed the same input that @iter@ was).  If @iter@ throws
-- any other type of exception, @ifParse@ passes the exception back
-- and does not execute @failure@.
--
ifParse :: (ChunkData t, Monad m) =>
           Iter t m a
        -- ^ Iteratee @iter@ to run with backtracking
        -> (a -> Iter t m b)
        -- ^ @success@ function
        -> Iter t m b
        -- ^ @failure@ action
        -> Iter t m b
        -- ^ result
ifParse iter yes no = do
  ea <- tryBI iter
  case ea of
    Right a  -> yes a
    Left err -> combineExpected err no

-- | This function is just 'ifParse' with the second and third
-- arguments reversed.
ifNoParse :: (ChunkData t, Monad m) =>
             Iter t m a -> Iter t m b -> (a -> Iter t m b) -> Iter t m b
ifNoParse iter no yes = ifParse iter yes no

{-
-- | LL(1) parser alternative.  @a \<|\> b@ starts by executing @a@.
-- If @a@ throws an exception of class 'IterNoParse' /and/ @a@ has not
-- consumed any input, then @b@ is executed.  (@a@ has consumed input
-- if it returns in the 'IterF' state after being fed a non-empty
-- 'Chunk'.)
--
-- Use of this combinator is somewhat error-prone, because it may be
-- difficult to tell whether Iteratee @a@ will ever consume input
-- before failing.  For this reason, it is safer to use 'orI', the
-- '\/' operator, or the '<&>' operator, all of which support
-- unlimited lookahead (LL(*) parsing) in different ways.
--
-- @\<|\>@ has fixity:
--
-- > infixr 3 <|>
(<|>) :: (ChunkData t, LL.ListLike t e, Monad m) =>
         Iter t m a -> Iter t m a -> Iter t m a
(<|>) = paranoidLL1
infixr 3 <|>

fastLL1 :: (ChunkData t, Monad m) => Iter t m a -> Iter t m a -> Iter t m a
fastLL1 a@(IterF _) b = IterF $ \c -> runIter a c >>= check c
    where
      check _ a1@(Done _ _) = return a1
      check c a1@(IterF _) | not (null c) = return a1
                           | otherwise    = return $ fastLL1 a1 b
      check c a1 = runIter (fastLL1 a1 b) c
fastLL1 a b = a `catchI` \err _ -> combineExpected err b


-- | To catch bugs that only get triggered on certain input
-- boundaries, this version of @<|>@ always just feeds the first
-- character to Iteratees.
paranoidLL1 :: (ChunkData t, LL.ListLike t e, Monad m) =>
               Iter t m a -> Iter t m a -> Iter t m a
paranoidLL1 a@(IterF _) b = IterF dorun
    where
      dorun c@(Chunk t eof)
          | LL.null t || LL.null (LL.tail t) = runIter a c >>= check c
          | otherwise                        = do
        let ch = Chunk (LL.singleton $ LL.head t) False
            ct = Chunk (LL.tail t) eof
        a2 <- runIter a ch >>= check ch
        runIter a2 ct
      check _ a1@(Done _ _) = return a1
      check c a1@(IterF _) | not (null c) = return a1
                           | otherwise    = return $ paranoidLL1 a1 b
      check c a1 = runIter (paranoidLL1 a1 b) c
paranoidLL1 a b = a `catchI` \err _ -> combineExpected err b
-}

--
-- Some super-basic Iteratees
--

-- | Throw an exception from an Iteratee.  The exception will be
-- propagated properly through nested Iteratees, which will allow it
-- to be categorized properly and avoid situations in which, for
-- instance, functions holding 'MVar's are prematurely terminated.
-- (Most Iteratee code does not assume the Monad parameter @m@ is in
-- the 'MonadIO' class, and so cannot use 'catch' or 'onException' to
-- clean up after exceptions.)  Use 'throwI' in preference to 'throw'
-- whenever possible.
throwI :: (Exception e) => e -> Iter t m a
throwI e = IterFail $ toException e

-- | Throw an exception of type 'IterEOF'.  This will be interpreted
-- by 'enumO' and 'enumI' as an end of file chunk when thrown by the
-- generator/codec.  It will also be interpreted by 'ifParse' and
-- 'multiParse' as an exception of type 'IterNoParse'.  If not caught
-- within the 'Iter' monad, the exception will be rethrown by 'run'
-- (and hence '|$') as an 'IOError' of type EOF.
throwEOFI :: String -> Iter t m a
throwEOFI loc = throwI $ IterEOF $ mkIOError eofErrorType loc Nothing Nothing

-- | Throw an iteratee error that describes expected input not found.
expectedI :: String -> Iter t m a
expectedI target = throwI $ IterExpected [target]

-- | Internal function used by 'tryI' and 'backtrackI' when re-propagating
-- exceptions that don't match the requested exception type.  (To make
-- the overall types of those two funcitons work out, a 'Right'
-- constructor needs to be wrapped around the returned failing
-- iteratee.)
fixError :: (ChunkData t, Monad m) =>
            Iter t m a -> Iter t m (Either x a)
fixError (EnumIFail e i) = EnumIFail e $ Right i
fixError (EnumOFail e i) = EnumOFail e $ liftM Right i
fixError iter            = IterFail $ getIterError iter

-- | If an 'Iter' succeeds and returns @a@, returns @'Right' a@.  If
-- the 'Iter' throws an exception @e@, returns @'Left' (e, i)@ where
-- @i@ is the state of the failing 'Iter'.
tryI :: (ChunkData t, Monad m, Exception e) =>
        Iter t m a
     -> Iter t m (Either (e, Iter t m a) a)
tryI = wrapI errToEither
    where
      errToEither (Done a c) = Done (Right a) c
      errToEither iter       = case fromException $ getIterError iter of
                                 Just e  -> return $ Left (e, iter)
                                 Nothing -> fixError iter

-- | Runs an 'Iter' until it no longer requests input, keeping a copy
-- of all input that was fed to it (which might be longer than the
-- input the 'Iter' actually consumed).
copyInput :: (ChunkData t, Monad m) =>
          Iter t m a
       -> Iter t m (Iter t m a, Chunk t)
copyInput iter1 = doit mempty iter1
    where
      doit acc iter@(IterF _) =
          IterF $ \c -> runIter iter c >>= return . doit (mappend acc c)
      doit acc (Done a c) = Done (return a, acc) c
      doit acc iter       = return (iter, acc)

-- | Simlar to 'tryI', but saves all data that has been fed to the
-- 'Iter', and rewinds the input if the 'Iter' fails.  Thus, if it
-- returns @'Left' exception@, the next 'Iter' to be invoked will see
-- the same input that caused the previous 'Iter' to fail.  (For this
-- reason, it makes no sense ever to call 'resumeI' on the 'Iter' you
-- get back from @backtrackI@, and @tryBI@ thus does not return the
-- failing Iteratee the way 'tryI' does.)
--
-- Because @tryBI@ saves a copy of all input, it can consume a lot of
-- memory and should only be used when the 'Iter' argument is known to
-- consume a bounded amount of data.
tryBI :: (ChunkData t, Monad m, Exception e) =>
         Iter t m a
      -> Iter t m (Either e a)
tryBI iter1 = copyInput iter1 >>= errToEither
    where
      errToEither (Done a c, _) = Done (Right a) c
      errToEither (iter, c)     = case fromException $ getIterError iter of
                                   Just e  -> Done (Left e) c
                                   Nothing -> fixError iter

-- | Catch an exception thrown by an 'Iter'.  Returns the failed
-- 'Iter' state, which may contain more information than just the
-- exception.  For instance, if the exception occured in an
-- enumerator, the returned 'Iter' will also contain an inner 'Iter'
-- that has not failed.  To avoid discarding this extra information,
-- you should not re-throw exceptions with 'throwI'.  Rather, you
-- should re-throw an exception by re-executing the failed 'Iter'.
-- For example, you could define an @onExceptionI@ function analogous
-- to the standard library @'onException'@ as follows:
--
-- @
--  onExceptionI iter cleanup =
--      iter \`catchI\` \\('SomeException' _) iter' -> cleanup >> iter'
-- @
--
-- If you wish to continue processing the iteratee after a failure in
-- an enumerator, use the 'resumeI' function.  For example:
--
-- @
--  action \`catchI\` \\('SomeException' e) iter ->
--      if 'isEnumError' iter
--        then do liftIO $ putStrLn $ \"ignoring enumerator failure: \" ++ show e
--                'resumeI' iter
--        else iter
-- @
--
-- @catchI@ catches both iteratee and enumerator failures.  However,
-- because enumerators are functions on iteratees, you must apply
-- @catchI@ to the /result/ of executing an enumerator.  For example,
-- the following code modifies 'enumPure' to catch and ignore an
-- exception thrown by a failing 'Iter':
--
-- > catchTest1 :: IO ()
-- > catchTest1 = myEnum |$ fail "bad Iter"
-- >     where
-- >       myEnum :: EnumO String IO ()
-- >       myEnum iter = catchI (enumPure "test" iter) handler
-- >       handler (SomeException _) iter = do
-- >         liftIO $ hPutStrLn stderr "ignoring exception"
-- >         return ()
--
-- Note that @myEnum@ is an 'EnumO', but it actually takes an
-- argument, @iter@, reflecting the usually hidden fact that 'EnumO's
-- are actually functions.  Thus, @catchI@ is wrapped around the
-- result of applying @'enumPure' \"test\"@ to an 'Iter'.
--
-- Another subtlety to keep in mind is that, when fusing enumerators,
-- the type of the outer enumerator must reflect the fact that it is
-- wrapped around an inner numerator.  Consider the following test, in
-- which an exception thrown by an inner enumerator is caught:
--
-- > inumBad :: (ChunkData t, Monad m) => EnumI t t m a
-- > inumBad = enumI' $ fail "inumBad"
-- > 
-- > catchTest2 :: IO ()
-- > catchTest2 = myEnum |.. inumBad |$ nullI
-- >     where
-- >       myEnum :: EnumO String IO (Iter String IO ())
-- >       myEnum iter = catchI (enumPure "test" iter) handler
-- >       handler (SomeException _) iter = do
-- >         liftIO $ hPutStrLn stderr "ignoring exception"
-- >         return $ return ()
--
-- Note the type of @myEnum :: EnumO String IO (Iter String IO ())@
-- reflects that it has been fused to an inner enumerator.  Usually
-- these enumerator result types are computed automatically and you
-- don't have to worry about them as long as your enumreators are
-- polymorphic in the result type.  However, to return a result that
-- suppresses the exception here, we must run @return $ return ()@,
-- invoking @return@ twice, once to create an @Iter String IO ()@, and
-- a second time to create an @Iter String IO (Iter String IO ())@.
-- (To avoid such nesting proliferation in 'EnumO' types, it is
-- sometimes easier to fuse multiple 'EnumI's together with '..|..',
-- before fusing them to an 'EnumO'.)
--
-- If you are only interested in catching enumerator failures, see the
-- functions 'enumCatch' and `inumCatch`, which catch enumerator but
-- not iteratee failures.
--
-- Note that @catchI@ only works for /synchronous/ exceptions, such as
-- IO errors (thrown within 'liftIO' blocks), the monadic 'fail'
-- operation, and exceptions raised by 'throwI'.  It is not possible
-- to catch /asynchronous/ exceptions, such as lazily evaluated
-- divide-by-zero errors, the 'throw' function, or exceptions raised
-- by other threads using @'throwTo'@.
catchI :: (Exception e, ChunkData t, Monad m) =>
          Iter t m a
       -- ^ 'Iter' that might throw an exception
       -> (e -> Iter t m a -> Iter t m a)
       -- ^ Exception handler, which gets as arguments both the
       -- exception and the failing 'Iter' state.
       -> Iter t m a
catchI iter handler = wrapI check iter
    where
      -- next possibility should be impossible
      -- check iter'@(IterF _)  = catchI iter' handler
      check iter'@(Done _ _) = iter'
      check err              = case fromException $ getIterError err of
                                 Just e  -> handler e err
                                 Nothing -> err

-- | Catch exception with backtracking.  This is a version of 'catchI'
-- that keeps a copy of all data fed to the iteratee.  If an exception
-- is caught, the input is re-wound before running the exception
-- handler.  Because this funciton saves a copy of all input, it
-- should not be used on Iteratees that consume unbounded amounts of
-- input.  Note that unlike 'catchI', this function does not return
-- the failing Iteratee, because it doesn't make sense to call
-- 'resumeI' on an Iteratee after re-winding the input.
catchBI :: (Exception e, ChunkData t, Monad m) =>
           Iter t m a
        -> (e -> Iter t m a)
        -> Iter t m a
catchBI iter handler = copyInput iter >>= uncurry check
    where
      check iter'@(Done _ _) _ = iter'
      check err input          = case fromException $ getIterError err of
                                   Just e -> Done () input >> handler e
                                   Nothing -> err

-- | A version of 'catchI' with the arguments reversed, analogous to
-- @'handle'@ in the standard library.  (A more logical name for this
-- function might be @handleI@, but that name is used for the file
-- handle iteratee.)
handlerI :: (Exception e, ChunkData t, Monad m) =>
          (e -> Iter t m a -> Iter t m a)
         -- ^ Exception handler
         -> Iter t m a
         -- ^ 'Iter' that might throw an exception
         -> Iter t m a
handlerI = flip catchI

-- | 'catchBI' with the arguments reversed.
handlerBI :: (Exception e, ChunkData t, Monad m) =>
             (e -> Iter t m a)
          -- ^ Exception handler
          -> Iter t m a
          -- ^ 'Iter' that might throw an exception
          -> Iter t m a
handlerBI = flip catchBI

-- | Used in an exception handler, after an enumerator fails, to
-- resume processing of the 'Iter' by the next enumerator in a
-- concatenated series.  See 'catchI' for an example.
resumeI :: (ChunkData t, Monad m) => Iter t m a -> Iter t m a
resumeI (EnumOFail _ iter) = iter
resumeI (EnumIFail _ iter) = return iter
resumeI iter               = iter

-- | Like 'resumeI', but if the failure was in an enumerator and the
-- iteratee is resumable, prints an error message to standard error
-- before invoking 'resumeI'.
verboseResumeI :: (ChunkData t, MonadIO m) => Iter t m a -> Iter t m a
verboseResumeI iter | isEnumError iter = do
  prog <- liftIO $ getProgName
  liftIO $ hPutStrLn stderr $ prog ++ ": " ++ show (getIterError iter)
  resumeI iter
verboseResumeI iter = iter

-- | Similar to the standard @'mapException'@ function in
-- "Control.Exception", but operates on exceptions propagated through
-- the 'Iter' monad, rather than language-level exceptions.
mapExceptionI :: (Exception e1, Exception e2, ChunkData t, Monad m) =>
                 (e1 -> e2) -> Iter t m a -> Iter t m a
mapExceptionI f iter1 = wrapI check iter1
    where
      check iter@(IterF _) = iter
      check iter@(Done _ _) = iter
      check (IterFail e)    = IterFail (doMap e)
      check (EnumOFail e i) = EnumOFail (doMap e) i
      check (EnumIFail e a) = EnumIFail (doMap e) a
      doMap e = case fromException e of
                  Just e' -> toException (f e')
                  Nothing -> e
                
-- | Sinks data like @\/dev\/null@, returning @()@ on EOF.
nullI :: (Monad m, Monoid t) => Iter t m ()
nullI = IterF $ return . check
    where
      check (Chunk _ True) = Done () chunkEOF
      check _              = nullI

-- | Returns any non-empty amount of input data.
dataI :: (Monad m, ChunkData t) => Iter t m t
dataI = IterF $ \(Chunk d eof) -> return $
        if null d then dataI else Done d (Chunk mempty eof)

-- | Returns a non-empty 'Chunk' or an EOF 'Chunk'.
chunkI :: (Monad m, ChunkData t) => Iter t m (Chunk t)
chunkI = IterF $ \c@(Chunk _ eof) -> return $
         if null c then chunkI else Done c (Chunk mempty eof)

-- | Wrap a function around an 'Iter' to transform its result.  The
-- 'Iter' will be fed 'Chunk's as usual for as long as it remains in
-- the 'IterF' state.  When the 'Iter' enters a state other than
-- 'IterF', @wrapI@ passes it through the tranformation function.
wrapI :: (ChunkData t, Monad m) =>
         (Iter t m a -> Iter t m b) -- ^ Transformation function
      -> Iter t m a                 -- ^ Original 'Iter'
      -> Iter t m b                 -- ^ Returns an 'Iter' whose
                                    -- result will be transformed by
                                    -- the transformation function
wrapI f iter@(IterF _) =
    IterF $ \c@(Chunk _ eof) -> runIter iter c >>= rewrap eof
    where
      rewrap _ iter'@(IterF _) = return $ wrapI f iter'
      rewrap eof iter'         =
          case f iter' of
            i@(IterF _) -> runIter i (Chunk mempty eof)
            i           -> return i
wrapI f iter = f iter

-- | Runs an Iteratee from within another iteratee (feeding it EOF if
-- it is in the 'IterF' state) so as to extract a return value.  The
-- return value is lifted into the invoking Iteratee monadic type.  If
-- the iteratee being run fails, then @runI@ will propagate the
-- failure by also failing.  In the event that the failure is an
-- enumerator failure (either 'EnumIFail' or 'EnumOFail'), @runI@
-- returns an 'EnumIFail' failure and includes the state of the
-- iteratee.
runI :: (ChunkData t1, ChunkData t2, Monad m) =>
        Iter t1 m a
     -> Iter t2 m a
runI iter@(IterF _)  = lift (runIter iter chunkEOF) >>= runI
runI (Done a _)      = return a
runI (IterFail e)    = IterFail e
runI (EnumIFail e i) = EnumIFail e i
runI (EnumOFail e i) = runI i >>= EnumIFail e

-- | Pop an 'Iter' back out of an 'EnumI', propagating any failure.
-- Any enumerator failure ('EnumIFail' or 'EnumOFail') will be
-- translated to an 'EnumOFail' state.
joinI :: (ChunkData tIn, ChunkData tOut, Monad m) =>
         Iter tOut m (Iter tIn m a)
      -> Iter tIn m a
joinI iter@(IterF _)  = lift (runIter iter chunkEOF) >>= joinI
joinI (Done i _)      = i
joinI (IterFail e)    = IterFail e
joinI (EnumIFail e i) = EnumOFail e i
joinI (EnumOFail e i) = EnumOFail e $ joinI i

-- | Allows you to look at the state of an 'Iter' by returning it into
-- an 'Iter' monad.  This is just like the monadic 'return' method,
-- except that, if the 'Iter' is in the 'IterF' state, then @returnI@
-- additionally feeds it an empty chunk.  Thus 'Iter's that do not
-- require data, such as @returnI $ liftIO $ ...@, will execute and
-- return a result (possibly reflecting exceptions) immediately.
returnI :: (ChunkData tOut, ChunkData tIn, Monad m) =>
           Iter tIn m a
        -> Iter tOut m (Iter tIn m a)
returnI iter@(IterF _) =
    IterF $ \c -> runIter iter mempty >>= return . flip Done c
returnI iter = return iter

-- | Return the the first element when the Iteratee data type is a list.
headI :: (Monad m) => Iter [a] m a
headI = IterF $ return . dohead
    where
      dohead (Chunk [] True)    = throwEOFI "headI"
      dohead (Chunk [] _)       = headI
      dohead (Chunk (a:as) eof) = Done a $ Chunk as eof

-- | Return 'Just' the the first element when the Iteratee data type
-- is a list, or 'Nothing' on EOF.
safeHeadI :: (Monad m) => Iter [a] m (Maybe a)
safeHeadI = IterF $ return . dohead
    where
      dohead c@(Chunk [] True)  = Done Nothing c
      dohead (Chunk [] _)       = safeHeadI
      dohead (Chunk (a:as) eof) = Done (Just a) $ Chunk as eof

-- | An Iteratee that puts data to a consumer function, then calls an
-- eof function.  For instance, @'handleI'@ could be defined as:
--
-- > handleI :: (MonadIO m) => Handle -> Iter L.ByteString m ()
-- > handleI h = putI (liftIO . L.hPut h) (liftIO $ hShutdown h 1)
--
putI :: (ChunkData t, Monad m) =>
        (t -> Iter t m a)
     -> Iter t m b
     -> Iter t m ()
putI putfn eoffn = do
  Chunk t eof <- chunkI
  unless (null t) $ putfn t >> return ()
  if eof then eoffn >> return () else putI putfn eoffn

-- | Send datagrams using a supplied function.  The datagrams are fed
-- as a list of packets, where each element of the list should be a
-- separate datagram.
sendI :: (Monad m) =>
         (t -> Iter [t] m a)
      -> Iter [t] m ()
sendI sendfn = do
  dgram <- safeHeadI
  case dgram of
    Just pkt -> sendfn pkt >> sendI sendfn
    Nothing  -> return ()

--
-- Enumerator types
--

-- | An @EnumO t m a@ is an outer enumerator that gets data of type
-- @t@ by executing actions in monad @m@, then feeds the data in
-- chunks to an iteratee of type @'Iter' t m a@.  Most enumerators are
-- polymorphic in the last type, @a@, so as work with iteratees
-- returning any type.
--
-- An @EnumO@ is a function from iteratees to iteratees.  It
-- transforms an iteratee by repeatedly feeding it input until one of
-- four outcomes:  the iteratee returns a result, the iteratee fails,
-- the @EnumO@ runs out of input, or the @EnumO@ fails.  When one of
-- these four termination conditions holds, the @EnumO@ returns the
-- new state of the iteratee.
--
-- Under no circumstances should an @EnumO@ ever feed a chunk with the
-- EOF bit set to an iteratee.  When the @EnumO@ runs out of data, it
-- must simply return the current state of the iteratee.  This way
-- more data from another source can still be fed to the iteratee, as
-- happens when enumerators are concatenated with the 'cat' function.
--
-- @EnumO@s should generally be constructed using the 'enumO'
-- function, which takes care of most of the error-handling details.
type EnumO t m a = Iter t m a -> Iter t m a

-- | Concatenate two outer enumerators, forcing them to be executed in
-- turn in the monad @m@.  Note that the deceptively simple definition:
--
--  >  cat a b = b . a
--
-- wouldn't necessarily do the right thing, as in this case @a@'s
-- monadic actions would not actually get to run until @b@ executess
-- a, and @b@ might start out, before feeding any input to its
-- iteratee, by waiting for some event that is triggered by a
-- side-effect of @a@.  Has fixity:
--
-- > infixr 3 `cat`
cat :: (Monad m, ChunkData t) => EnumO t m a -> EnumO t m a -> EnumO t m a
cat a b iter = do
  iter' <- returnI $ a iter
  case iter' of
    IterF _ -> b iter'
    _       -> iter'
infixr 3 `cat`

-- | Run an outer enumerator on an iteratee.  Any errors in inner
-- enumerators that have been fused to the iteratee (in the second
-- argument of @|$@) will be considered iteratee failures.  Any
-- failures that are not caught by 'catchI', 'enumCatch', or
-- 'inumCatch' will be thrown as exceptions.  Has fixity:
--
-- > infixr 2 |$
(|$) :: (ChunkData t, Monad m) => EnumO t m a -> Iter t m a -> m a
(|$) enum iter = run $ enum $ wrapI (>>= return) iter
-- The purpose of the wrapI (>>= return) is to convert any EnumIFail
-- (or, less likely, EnumOFail) errors thrown by iter to IterFail
-- errors, so that enumCatch statements only catch enumerator
-- failures.
infixr 2 |$

-- | An inner enumerator or transcoder.  Such a function accepts data
-- from some outer enumerator (acting like an Iteratee), then
-- transcodes the data and feeds it to another Iter (hence also acting
-- like an enumerator towards that inner Iter).  Note that data is
-- viewed as flowing inwards from the outermost enumerator to the
-- innermost iteratee.  Thus @tOut@, the \"outer type\", is actually
-- the type of input fed to an @EnumI@, while @tIn@ is what the
-- @EnumI@ feeds to an iteratee.
--
-- As with @EnumO@, an @EnumI@ is a function from iteratees to
-- iteratees.  However, an @EnumI@'s input and output types are
-- different.  A simpler alternative to @EnumI@ might have been:
--
-- > type EnumI' tOut tIn m a = Iter tIn m a -> Iter tOut m a
--
-- In fact, given an @EnumI@ object @enumI@, it is possible to
-- construct such a function as @(enumI '..|')@.  But sometimes one
-- might like to concatenate @EnumI@s.  For instance, consider a
-- network protocol that changes encryption or compression modes
-- midstream.  Transcoding is done by @EnumI@s.  To change transcoding
-- methods after applying an @EnumI@ to an iteratee requires the
-- ability to \"pop\" the iteratee back out of the @EnumI@ so as to be
-- able to hand it to another @EnumI@.  The 'joinI' function provides
-- this popping function in its most general form, though if one only
-- needs 'EnumI' concatenation, the simpler 'catI' function serves
-- this purpose.
--
-- As with 'EnumO's, an @EnumI@ must never feed an EOF chunk to its
-- iteratee.  Instead, upon receiving EOF, the @EnumI@ should simply
-- return the state of the inner iteratee (this is how \"popping\" the
-- iteratee back out works).  An @EnumI@ should also return when the
-- iteratee returns a result or fails, or when the @EnumI@ fails.  An
-- @EnumI@ may return the state of the iteratee earlier, if it has
-- reached some logical message boundary (e.g., many protocols finish
-- processing headers upon reading a blank line).
--
-- @EnumI@s are generally constructed with the 'enumI' function, which
-- hides most of the error handling details.
type EnumI tOut tIn m a = Iter tIn m a -> Iter tOut m (Iter tIn m a)

-- | Concatenate two inner enumerators.  Has fixity:
--
-- > infixr 3 `catI`
catI :: (ChunkData tOut, ChunkData tIn, Monad m) =>
        EnumI tOut tIn m a      -- ^
     -> EnumI tOut tIn m a
     -> EnumI tOut tIn m a
catI a b = a >=> b
infixr 3 `catI`

-- | Fuse an outer enumerator, producing chunks of some type @tOut@,
-- with an inner enumerator that transcodes @tOut@ to @tIn@, to
-- produce a new outer enumerator producing chunks of type @tIn@.  Has
-- fixity:
--
-- > infixl 4 |..
(|..) :: (ChunkData tOut, ChunkData tIn, Monad m) =>
         EnumO tOut m (Iter tIn m a) -- ^
      -> EnumI tOut tIn m a
      -> EnumO tIn m a
(|..) outer inner iter = joinI $ outer $ inner iter
infixl 4 |..

-- | Fuse two inner enumerators into one.  Has fixity:
--
-- > infixl 5 ..|..
(..|..) :: (ChunkData tOut, ChunkData tMid, ChunkData tIn, Monad m) => 
           EnumI tOut tMid m (Iter tIn m a) -- ^
        -> EnumI tMid tIn m a
        -> EnumI tOut tIn m a
(..|..) outer inner iter = wrapI (return . joinI . joinI) $ outer $ inner iter
infixl 5 ..|..

-- | Fuse an inner enumerator that transcodes @tOut@ to @tIn@ with an
-- iteratee taking type @tIn@ to produce an iteratee taking type
-- @tOut@.  Has fixity:
--
-- > infixr 4 ..|
(..|) :: (ChunkData tOut, ChunkData tIn, Monad m) =>
         EnumI tOut tIn m a     -- ^
      -> Iter tIn m a
      -> Iter tOut m a
(..|) inner iter = wrapI (runI . joinI) $ inner iter
infixr 4 ..|

-- | A @Codec@ is an 'Iter' that tranlates data from some input type
-- @tArg@ to an output type @tRes@ and returns the result in a
-- 'CodecR'.  If the @Codec@ is capable of repeatedly being invoked to
-- translate more input, it returns a 'CodecR' in the 'CodecF' state.
-- This convention allows @Codec@s to maintain state from one
-- invocation to the next by currying the state into the codec
-- function the next time it is invoked.  A @Codec@ that cannot
-- process more input returns a 'CodecR' in the 'CodecE' state.
type Codec tArg m tRes = Iter tArg m (CodecR tArg m tRes)

-- | The result type of a 'Codec' that translates from type @tArg@ to
-- @tRes@ in monad @m@.  The result potentially includes a new 'Codec'
-- for translating subsequent input.
data CodecR tArg m tRes = CodecF { unCodecF :: (Codec tArg m tRes)
                                 , unCodecR :: tRes }
                          -- ^ This is the normal 'Codec' result,
                          -- which includes another 'Codec' (often the
                          -- same as one that was just called) for
                          -- processing further input.
                        | CodecE { unCodecR :: tRes }
                          -- ^ This constructor is used if the 'Codec'
                          -- is ending--i.e., returning for the last
                          -- time--and thus cannot provide another
                          -- 'Codec' to process further input.
                        | CodecX
                          -- ^ An alternative to 'CodecE' when the
                          -- 'Codec' is ending and additionally did
                          -- not receive enough input to produce one
                          -- last item.

-- | Transform an ordinary 'Iter' into a stateless 'Codec'.
iterToCodec :: (ChunkData t, Monad m) => Iter t m a -> Codec t m a
iterToCodec iter = iter >>= return . CodecF (iterToCodec iter)

-- | Creates a 'Codec' from an 'Iter' @iter@ that returns 'Chunk's.
-- The 'Codec' returned will keep offering to translate more input
-- until @iter@ returns a 'Chunk' with the EOF bit set.
chunkerToCodec :: (ChunkData t, Monad m) => Iter t m (Chunk a) -> Codec t m a
chunkerToCodec iter = do
  Chunk d eof <- iter
  if eof
   then return $ CodecE d
   else return $ CodecF (chunkerToCodec iter) d

-- | Build an 'EnumO' from a @before@ action, an @after@ function, and
-- an @input@ function in a manner analogous to the IO 'bracket'
-- function.  For instance, you could implement @`enumFile'`@ as
-- follows:
--
-- >   enumFile' :: (MonadIO m) => FilePath -> EnumO L.ByteString m a
-- >   enumFile' path =
-- >     enumObracket (liftIO $ openFile path ReadMode) (liftIO . hClose) doGet
-- >       where
-- >         doGet h = do
-- >           buf <- liftIO $ L.hGet h 8192
-- >           if (L.null buf)
-- >             then return chunkEOF
-- >             else return $ chunk buf
--
enumObracket :: (Monad m, ChunkData t) =>
                (Iter () m b)
             -- ^ Before action
             -> (b -> Iter () m c)
             -- ^ After action, as function of before action result
             -> (b -> Iter () m (Chunk t))
             -- ^ Chunk generating function, as a funciton of before
             -- aciton result
             -> EnumO t m a
enumObracket before after input iter = do
  eb <- tryI $ runI before
  case eb of
    Left (e,_) -> EnumOFail e iter
    Right b    -> do
            iter' <- returnI $ enumO (chunkerToCodec $ input b) iter
            ec <- tryI $ runI (after b)
            case ec of
              Left (e,_) | not $ isIterError iter' -> EnumOFail e iter'
              _                                    -> iter'

-- | Construct an outer enumerator given a function that produces
-- 'Chunk's of type @t@.
enumO :: (Monad m, ChunkData t) =>
         Codec () m t
         -- ^ This is the computation that produces input.  It is run
         -- with EOF, and never gets fed any input.  The type of this
         -- argument could alternatively have been just @m t@, but
         -- then there would be no way to signal failure.  (We don't
         -- want to assume @m@ is a member of @MonadIO@; thus we
         -- cannot catch exceptions that aren't propagated via monadic
         -- types.)
      -> EnumO t m a
         -- ^ Returns an outer enumerator that feeds input chunks
         -- (obtained from the first argument) into an iteratee.
enumO codec0 iter@(IterF _) = (lift $ runIter codec0 chunkEOF) >>= check
    where
      check (Done (CodecE t) _) =
          lift (runIter iter $ chunk t) >>= id
      check (Done (CodecF codec t) _) =
          lift (runIter iter $ chunk t) >>= enumO codec
      check codec
          | isIterEOFError codec = iter
          | otherwise            = EnumOFail (getIterError codec) iter
enumO _ iter = iter

-- | Like 'enumO', but the input function returns raw data, not
-- 'Chunk's.  The only way to signal EOF is therefore to raise an
-- EOF exception.
enumO' :: (Monad m, ChunkData t) =>
          Iter () m t
       -> EnumO t m a
enumO' input iter = enumO (iterToCodec input) iter

-- | Build an inner enumerator given a 'Codec' that returns chunks of
-- the appropriate type.  Makes an effort to send an EOF to the codec
-- if the inner 'Iter' fails, so as to facilitate cleanup.  However,
-- if a containing 'EnumO' or 'EnumI' fails, code handling that
-- failure will have to send an EOF or the codec will not be able to
-- clean up.
enumI :: (Monad m, ChunkData tOut, ChunkData tIn) =>
         Codec tOut m tIn
      -- ^ Codec to be invoked to produce transcoded chunks.
      -> EnumI tOut tIn m a
enumI codec0 iter0@(IterF _) = IterF $ \cOut -> do
  codec <- runIter codec0 cOut
  case codec of
    IterF _                        -> return $ enumI codec iter0
    Done CodecX cOut'              -> return $ Done iter0 cOut'
    Done (CodecE dat) cOut'        -> do iter' <- runIter iter0 (chunk dat)
                                         return $ Done iter' cOut'
    Done (CodecF codec' dat) cOut' -> do iter' <- runIter iter0 (chunk dat)
                                         check codec' cOut' iter'
    _ | isIterEOFError codec       -> return $ return iter0
    _                              -> return $ EnumIFail
                                               (getIterError codec) iter0
    where
      check codec cOut@(Chunk _ eof) iter
            | eof && not (isIterF iter) = return $ Done iter cOut
            | otherwise                 = runIter (enumI codec iter) cOut
-- If iter finished, still must feed EOF to codec before returning iter
enumI codec iter = IterF $ \(Chunk t eof) -> do
  codec' <- runIter codec (Chunk t True)
  return $ case codec' of
             Done _ (Chunk t' _) -> Done iter (Chunk t' eof)
             _ -> EnumIFail (getIterError codec') iter

-- | Transcode (until codec throws an EOF error, or until after it has
-- received EOF).
enumI' :: (Monad m, ChunkData tOut, ChunkData tIn) =>
          Iter tOut m tIn
       -- ^ This Iteratee will be executed repeatedly to produce
       -- transcoded chunks.
       -> EnumI tOut tIn m a
enumI' fn iter = enumI (iterToCodec fn) iter

--
-- Basic outer enumerators
--

-- | An 'EnumO' that will feed pure data to 'Iter's.
enumPure :: (Monad m, ChunkData t) => t -> EnumO t m a
enumPure t = enumO $ return $ CodecE t

-- | Like 'catchI', but applied to 'EnumO's and 'EnumI's instead of
-- 'Iter's, and does not catch errors thrown by 'Iter's.
--
-- There are three 'catch'-like functions in the iterIO library,
-- catching varying numbers of types of failures.  @inumCatch@ is the
-- middle option.  By comparison:
--
-- * 'catchI' catches the most errors, including those thrown by
--   'Iter's.  'catchI' can be applied to 'Iter's, 'EnumI's, or
--   'enumO's, and is useful both to the left and to the right of
--   '|$'.
--
-- * @inumCatch@ catches 'EnumI' or 'EnumO' failures, but not 'Iter'
--   failures.  It can be applied to 'EnumI's or 'EnumO's, to the left
--   or to the right of '|$'.  When applied to the left of '|$', will
--   not catch any errors thrown by 'EnumI's to the right of '|$'.
--
-- * 'enumCatch' only catches 'EnumO' failures, and should only be
--   applied to the left of '|$'.  (You /can/ apply 'enumCatch' to
--   'EnumI's or to the right of '|$', but this is not useful because
--   it ignores 'Iter' and 'EnumI' failures so won't catch anything.)
--
-- One potentially unintuitive apsect of @inumCatch@ is that, when
-- applied to an enumerator, it catches any enumerator failure to the
-- right that is on the same side of '|$'--even enumerators not
-- lexically scoped within the argument of @inumCatch@.  See
-- 'enumCatch' for some examples of this behavior.
inumCatch :: (Exception e, ChunkData t, Monad m) =>
              EnumO t m a
           -- ^ 'EnumO' that might throw an exception
           -> (e -> Iter t m a -> Iter t m a)
           -- ^ Exception handler
           -> EnumO t m a
inumCatch enum handler = wrapI check . enum
    where
      check iter'@(Done _ _)   = iter'
      check iter'@(IterFail _) = iter'
      check err                = case fromException $ getIterError err of
                                   Just e  -> handler e err
                                   Nothing -> err

-- | Like 'catchI', but for 'EnumO's instead of 'Iter's.  Catches
-- errors thrown by an 'EnumO', but /not/ those thrown by 'EnumI's
-- fused to the 'EnumO' after @enumCatch@ has been applied, and not
-- exceptions thrown from an 'Iter'.  If you want to catch all
-- enumerator errors, including those from subsequently fused
-- 'EnumI's, see the `inumCatch` function.  For example, compare
-- @test1@ (which throws an exception) to @test2@ and @test3@ (which
-- do not):
--
-- >    inumBad :: (ChunkData t, Monad m) => EnumI t t m a
-- >    inumBad = enumI' $ fail "inumBad"
-- >    
-- >    skipError :: (ChunkData t, MonadIO m) =>
-- >                 SomeException -> Iter t m a -> Iter t m a
-- >    skipError e iter = do
-- >      liftIO $ hPutStrLn stderr $ "skipping error: " ++ show e
-- >      resumeI iter
-- >    
-- >    -- Throws an exception
-- >    test1 :: IO ()
-- >    test1 = enumCatch (enumPure "test") skipError |.. inumBad |$ nullI
-- >    
-- >    -- Does not throw an exception, because inumCatch catches all
-- >    -- enumerator errors on the same side of '|$', including from
-- >    -- subsequently fused inumBad.
-- >    test2 :: IO ()
-- >    test2 = inumCatch (enumPure "test") skipError |.. inumBad |$ nullI
-- >    
-- >    -- Does not throw an exception, because enumCatch was applied
-- >    -- after inumBad was fused to enumPure.
-- >    test3 :: IO ()
-- >    test3 = enumCatch (enumPure "test" |.. inumBad) skipError |$ nullI
--
-- Note that both @\`enumCatch\`@ and ``inumCatch`` have the default
-- infix precedence (9), which binds more tightly than any
-- concatenation or fusing operators.
enumCatch :: (Exception e, ChunkData t, Monad m) =>
              EnumO t m a
           -- ^ 'EnumO' that might throw an exception
           -> (e -> Iter t m a -> Iter t m a)
           -- ^ Exception handler
           -> EnumO t m a
enumCatch enum handler = wrapI check . enum
    where
      check iter@(EnumOFail e _) =
          case fromException e of
            Just e' -> handler e' iter
            Nothing -> iter
      check iter = iter

-- | 'enumCatch' with the argument order switched.
enumHandler :: (Exception e, ChunkData t, Monad m) =>
               (e -> Iter t m a -> Iter t m a)
            -- ^ Exception handler
            -> EnumO t m a
            -- ^ 'EnumO' that might throw an exception
            -> EnumO t m a
enumHandler = flip enumCatch

-- | Create a loopback @('Iter', 'EnumO')@ pair.  The iteratee and
-- enumerator can be used in different threads.  Any data fed into the
-- 'Iter' will in turn be fed by the 'EnumO' into whatever 'Iter' it
-- is given.  This is useful for testing a protocol implementation
-- against itself.
iterLoop :: (MonadIO m, ChunkData t, Show t) =>
            m (Iter t m (), EnumO t m a)
iterLoop = do
  -- The loopback is implemented with an MVar (MVar Chunk).  The
  -- enumerator waits on the inner MVar, while the iteratee uses the outer 
  -- MVar to avoid races when appending to the stored chunk.
  pipe <- liftIO $ newEmptyMVar >>= newMVar
  return (IterF $ iterf pipe, enum pipe)
    where
      iterf pipe c@(Chunk _ eof) = do
             liftIO $ withMVar pipe $ \p ->
                 do mp <- tryTakeMVar p
                    putMVar p $ case mp of
                                  Nothing -> c
                                  Just c' -> mappend c' c
             return $ if eof
                      then Done () chunkEOF
                      else IterF $ iterf pipe

      enum pipe = enumO $ chunkerToCodec $ do
                    p <- liftIO $ readMVar pipe
                    c <- liftIO $ takeMVar p
                    return c

--
-- Basic inner enumerators
--

-- | The null 'EnumI', which passes data through to another iteratee
-- unmodified.
inumNop :: (ChunkData t, Monad m) => EnumI t t m a
inumNop = enumI $ chunkerToCodec chunkI

-- | Returns an 'Iter' that always returns itself until a result is
-- produced.  You can fuse @inumSplit@ to an 'Iter' to produce an
-- 'Iter' that can safely be written from multiple threads.
inumSplit :: (MonadIO m, ChunkData t) => EnumI t t m a
inumSplit iter1 = do
  mv <- liftIO $ newMVar $ iter1
  IterF $ iterf mv
    where
      iterf mv (Chunk t eof) = do
        rold <- liftIO $ takeMVar mv
        rnew <- runIter rold $ chunk t
        liftIO $ putMVar mv rnew
        return $ case rnew of
                   IterF _ | not eof -> IterF $ iterf mv
                   _                 -> return rnew


