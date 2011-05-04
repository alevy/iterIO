
{- |

This is the main module to import for the IterIO package.  It
re-exports several other modules and mostly consists of
documentation--first a high-level overview of the iteratee model, then
a more detailed tutorial, finally a discussion of the differences from
other iteratee packages and acknowledgments.

See the "Data.IterIO.Iter", "Data.IterIO.Inum", and
"Data.IterIO.ListLike" modules for more detailed documentation of data
structures and functions.  In addition, "Data.IterIO.Trans" (also
re-exported by this module) supplies functions that help you invoke
monad transformers from the mtl library from within the 'Iter' monad.

Several other potentially useful modules in the package are not
exported by default:

 * "Data.IterIO.Parse" includes parsec-like parsing combinators for
   iteratee input.

 * "Data.IterIO.Zlib" provides zlib and gzip format compression and
   decompression.

 * "Data.IterIO.SSL" provides support for SSL.

 * "Data.IterIO.Http" provides support for parsing and formatting
   HTTP, including handling form and file uploads (which can be
   processed in constant space).  This may be useful in conjunction
   with "Data.IterIO.HttpRoute", which provides simple request routing
   support for web servers.

 * "Data.IterIO.Atto" provides support for running attoparsec parsers
   on iteratee input (see
   <http://hackage.haskell.org/package/attoparsec/>).

 * "Data.IterIO.Extra" provides debugging functions, as well as a
   loopback iteratee that can be used to test a protocol
   implementation against itself.

-}

module Data.IterIO
    (module Data.IterIO.Iter
    , module Data.IterIO.Trans
    , module Data.IterIO.Inum
    , module Data.IterIO.ListLike

    -- * Overview
    -- $Overview

    -- * Tutorial
    -- $Tutorial

    -- * Differences from other iteratee packages
    -- $Differences

    -- * Acknowledgments
    -- $Acknowledgments
    ) where

import Data.IterIO.Iter hiding (null, run -- names that might collide
                               )
import Data.IterIO.Trans
import Data.IterIO.Inum
import Data.IterIO.ListLike

{- $Overview

   At a high level, an iteratee is a data sink that is fed chunks of
   data.  It may return a useful result, or its utility may lie in
   monadic side-effects, such as storing received data to a file.
   Iteratees are represented by the type @'Iter' t m a@.  Here @t@ is
   the type of data that the iteratee receives as input.  (@t@ must be
   an instance of 'ChunkData', such as 'String' or lazy @ByteString@.)
   @m@ is the 'Monad' in which the iteratee runs--for instance 'IO'
   (or an instance of 'MonadIO') for the iteratee to perform IO.  @a@
   is the type that the iteratee will return when it has consumed
   enough input to produce a result.

   An enumerator is a data source that feeds data chunks to an
   iteratee.  Enumerators are also iteratees.  We use the type @'Inum'
   tIn tOut m a@ to represent these /iteratee-enumerators/.  As an
   iteratee, an 'Inum' sinks data of some input type, generally
   designated @tIn@.  As an enumerator, the 'Inum' feeds data of a
   potentially different type, @tOut@, to another iteratee.  Thus, the
   'Inum' can be viewed as transcoding data from type @tIn@ to type
   @tOut@ for consumption by another iteratee.

   'Inum's are generally constructed using the functions @'mkInum'@
   and @'mkInumM'@ in module "Data.IterIO.Inum".  The first function
   uses a simple @'Iter' tIn m tOut@ to translate between input type
   @tIn@ and output type @tOut@.  The second function, @'mkInumM'@,
   allows construction of more complex 'Inum's.

   An important special kind of 'Inum' is an /outer enumerator/,
   which is just an 'Inum' with the void input type @()@.  Outer
   enumerators are sources of data.  Rather than transcode input
   data, they produce data from monadic actions (or from pure data
   in the case of 'inumPure').  The type 'Onum' represents outer
   enumerators and is a synonym for 'Inum' with an input type of
   @()@.

   To execute iteratee-based IO, you must apply an 'Onum' to an
   'Iter' with the '|$' (\"pipe apply\") binary operator.

   An important property of enumerators and iteratees is that they can
   be /fused/.  The '|.' (\"fuse leftward\") operator fuses two
   'Inum's together (provided the output type of the first is the
   input type of the second), yielding a new 'Inum' that transcodes
   from the input type of the first to the output type of the second.
   Similarly, the '.|' (\"fuse rightwart\") operator fuses an 'Inum'
   to an 'Iter', yielding a new 'Iter' with a potentially different
   input type.

   Enumerators of the same type can also be /concatenated/, using
   the 'cat' function.  @enum1 ``cat`` enum2@ produces an enumerator
   whose effect is to feed first @enum1@'s data then @enum2@'s data
   to an 'Iter'.
-}

{- $Tutorial

#tutorial#

The iterIO library performs IO by hooking up sources of data, called
/enumerators/, to data sinks, called /iteratees/, in a manner
reminiscent of Unix command pipelines.  Compared to lazy IO, the
enumerator/iteratee paradigm provides better error handing,
referential transparency (which should, after all, be one of the big
advantages of Haskell), and equally convenient composition of protocol
layers and parsers without worrying about IO chunk boundaries.

Enumerators, implemented by the type 'Onum' (short for
/outer enumerator/, for reasons that will become clear below), are so
called because they enumerate all data elements (e.g., bytes or
packets) in some source such as a file or socket.  Hence, an
enumerator should be viewed as a /source/ outputting chunks of data
whose type is a @'Monoid'@.  (Actually, the input type must be of
class 'ChunkData', which is a @'Monoid'@ that additionally has a
method @'null'@ to test whether a piece of data is equal to
'mempty'.)

Iteratees, implemented by the type 'Iter', should be viewed as /sinks/
consuming data.  When executing IO, the library /iterates/ over all
data elements output by the source, using an iteratee to produce a
result.  The source may output data in chunks whose boundaries do not
coincide with logical message units; iteratees handle this
transparently, simplifying programming.

Here is a simple example:

@
    -- Return the first line of a file
    headFile :: FilePath -> IO String
    headFile path = 'enumFile' path '|$' 'lineI'
@

'enumFile' enumerates the contents of a file.  'lineI' returns a line
of input (discarding the newline).  '|$' is the /pipe apply/ operator
that applies an 'Onum' to an 'Iter', returning the result of the
'Iter'--in this case the first line of the file named @path@.

An `Iter`'s main purpose may not be to produce a result.  Some 'Iter's
are primarily useful for their side effects.  For example, 'stdoutI'
writes data to standard output; 'handleI' similarly writes output to
an arbitrary file handle.  Thus, the following function copies the
contents of a file to standard output:

@
    -- Copy file to standard output
    catFile :: FilePath -> IO ()
    catFile path = 'enumFile'' path '|$' 'stdoutI'
@

'enumFile'' is like 'enumFile' above, but type restricted to data in
the lazy @'ByteString'@ format, which is more efficient than plain
'String's.  ('enumFile' supports multiple types, but in this example
there is not enough information for Haskell to choose one of them, so
we must use 'enumfile'' or use @::@ to specify a type explicitly.)
Once again, '|$' is used to execute the IO actions, but, this time,
the return value is just @()@; the interesting action lies in the side
effects of writing data to standard output while iterating over the
input with 'stdoutI'.

The real power of the iteratee abstraction lies in the fact that
'Iter's are monadic computations.  One 'Iter' may invoke another to
make use of the first one's results.  Here is an example of a function
that returns the first two lines of a file:

@
    -- | Return first two lines of file
    head2File :: FilePath -> IO (String, String)
    head2File path = 'enumFile' path '|$' lines2I
@

@
    -- | Iter that returns next two lines as a pair
    lines2I :: (Monad m) => 'Iter' String m (String, String)
    lines2I = do
      line1 <- 'lineI'
      line2 <- 'lineI'
      return (line1, line2)
@

This example illustrates several points.  First, consider the type of
the @lines2I@ function:  @'Iter' String m (String, String)@.  The
'Iter' type constructor takes three type arguments.  The first,
'String' in this case, specifies the type of input expected by the
iteratee.  The last type, @(String, String)@ in this case, specifies
the result type of the iteratee.  Finally, the middle type, @m@, is a
monad, because @'Iter' t@ (for a given input type @t@) is a monad
transformer (i.e., it is an instance of the 'MonadTrans' class).  In
this case, when @head2File@ invokes @lines2I@, @m@ will be @IO@,
because @head2File@ is returning a result in the @IO@ monad.  However,
@lines2I@ would work equally well with any other monad.

Next, notice the functioning of @'Iter' String m@ as a monad.  The
type of 'lineI' in the above example is @'Iter' String m String@.  The
@lines2I@ function executes 'lineI' twice using monadic @do@ syntax to
bind the results to @line1@ and @line2@.  The monadic bind operator
hides the details of IO chunk boundaries.  If, for instance, 'lineI'
needs more input because a newline character has not yet been read,
'lineI' returns to the containing enumerator asking for more data.  If
the first 'lineI' receives more than a line of input, it simply passes
the residual input to the next invocation of 'lineI'.  Both of these
actions are hidden by the syntax, making most code much easier to read
and write.

That explains the iteratee type 'Iter'.  The enumerator type, 'Onum',
has the same three type arguments.  Thus, the type of 'enumFile', as
instantiated in the above examples, is @'enumFile' :: 'Onum' String IO
a@.  Most 'Onum' types are polymorphic in the last argument, so as to
be able to return whatever type the 'Iter' is returning.  (In fact,
'enumFile' is polymorphic in the first two arguments, too, so as to
work with multiple @String@-like types and any monad in the
@'MonadIO'@ class.)

Here is an example of an 'Iter' with side effects:

@
    liftIOexampleI :: (MonadIO m) => 'Iter' String m ()
    liftIOexampleI = do
      line <- 'lineI'
      'liftIO' $ putStrLn $ \"First line is: \" ++ line
      next <- 'takeI' 40
      'liftIO' $ putStrLn $ \"And the next 40 bytes are: \" ++ next
@

Unlike @lines2I@, @liftIOexampleI@ does not return any interesting
result, but it uses the @'liftIO'@ monad transformer method to output
the first line of the file, followed by the next 40 bytes.  The
'takeI' iteratee returns a 'String' (or @ByteString@) with exactly the
requested number of characters or bytes, unless an EOF (end-of-file)
is encountered.

Of course, the real power of command pipelines is that you can hook
multiple commands together.  For instance, say you want to know how
many words in the system dictionary files contain a double k and start
with a lower-case letter.  You could run a command like this:

>    cat /usr/share/dict/words /usr/share/dict/extra.words \
>        | grep kk | grep '^[a-z]' | wc -l

Let's see how to do something equivalent with iteratees, starting with
the @wc -l@ command, which counts lines.  Here is an equivalent iteratee:

@
    lineCountI :: (Monad m) => 'Iter' String m Int
    lineCountI = count 0
        where count n = do
                line <- 'safeLineI'
                case line of
                  Just _  -> count (n+1)
                  Nothing -> return n
@

The 'safeLineI' function is like 'lineI', but returns a @'Maybe'
'String'@ (or @'Maybe' 'ByteString'@) which is 'Nothing' upon an EOF
condition.  ('lineI' throws an exception on EOF.)

What about the @grep@ command?  @grep@ sits in the middle of a
pipeline, so it acts both as a data sink and as a data source.
This is why we call such a pipeline stage an
/iteratee-enumerator/, or 'Inum'.  Before defining our @grep@
equivalent, since multiple pipeline stages are going to be considering
the file one line at a time, let's first build an 'Inum' to separate
input into lines:

@
    import Data.ByteString as S
    import Data.ByteString.Char8 as S8
@

@
    -- | Break input into lines of type S.ByteString, as this type
    -- works most conveniently with regular expressions.  (Otherwise,
    -- we would prefer lazy ByteStrings.)
    inumToLines :: (Monad m) => 'Inum' S.ByteString [S.ByteString] m a
    inumToLines = 'mkInum' $ do
                    line <- 'lineI'
                    return [line]
@

'Inum' takes four type arguments, compared to only three for 'Onum'.
That's because an 'Inum' is acting as both an iteratee and an
enumerator; it needn't be processing the same type of data in both
roles.  In the above example, when acting as an iteratee,
@inumToLines@ consumes data of type @S.ByteString@ (the first type
argument), accepting one long stream of unstructured bytes.  However,
as an enumerator, @inumToLines@ produces output of type
@[S.ByteString]@ (the second type argument), a /list/ of strings, one
per line of the file.  In general the type @'Inum' tIn tOut m a@ is an
iteratee-enumerator taking input type @tIn@, producing output type
@tOut@, and feeding the output to an iteratee of type @'Iter' tOut m
a@.

In fact, an 'Onum' is just a special kind of 'Inum' with the void
input type @()@.  The type @'Onum' t m a@ is just a synonym for
@'Inum' () t m a@.  Most operations on 'Inum's can be used with
'Onum's as well, since an 'Onum' /is/ an 'Inum'.  The converse is not
true, however.  For example, the '|$' operator requires an 'Onum', as
it wouldn't know what data to feed to an arbitrary 'Inum'.  (If you
need it, however, there is a function @run@, hidden by this module but
exported by "Data.IterIO.Iter", that executes an iteratee computation
of arbitrary input type by feeding EOF as input.)

Iteratee-enumerators are generally constructed using either 'mkInum'
or `mkInumM`, and by convention most 'Inum's have names starting
\"@inum@...\", except that 'Onum' names start \"@enum@...\".  'mkInum'
takes an argument of type @'Iter' tIn m tOut@ that consumes input of
type @tIn@ to produce output of type @tOut@.  (For @inumToLines@,
@tIn@ is @S.ByteString@ and @tOut@ is @[S.ByteString]@).  This is fine
for simple stateless translation functions, but sometimes one would
like to keep state and use more complex logic in an 'Inum'.  For that,
the 'mkInumM' function creates an 'Inum' out of a computation in a
dedicated 'InumM' monad.  See the "Data.IterIO.Inum" documentation for
more informaiton on 'mkInumM'.  In @inumToLines@, we do not need to
keep state.  We are happy just to let 'lineI' throw an exception on
EOF, which `mkInum` will catch and handle gracefully.

Throwing an EOF exception--either implicitly by executing another
'Iter', or explicitly with 'throwEOFI'--is one of the standard ways to
exit an 'Inum' created by 'mkInum'.  The other way is to return empty
input.

We similarly define an 'Inum' to filter out lines not matching a
regular expression (using the "Text.Regex.Posix.ByteString" library),
and a simple 'Inum' to count list elements (since @lineCountI ::
'Iter' String m Int@ has input data type @String@, while after
@inumToLines@ we need an 'Iter' with input data type
@[S.ByteString]@).

@
    inumGrep :: (Monad m) => String -> 'Inum' [S.ByteString] [S.ByteString] m a
    inumGrep re = `mkInum` $ do
      line <- 'headI'
      if line =~ packedRe then return [line] else inumGrep re
        where
          packedRe = S8.pack re
@

@
    lengthI :: (Monad m) => 'Iter' [t] m Int
    lengthI = count 0
        where count n = do
                line <- 'safeHeadI'
                case line of
                  Just _  -> count (n+1)
                  Nothing -> return n
@

Notice that when a line doesn't match, @inumGrep@ calls itself
recursively.  This is necessary because returning an empty list of
lines signals to 'mkInum' that there is no more input.  Thus, the
following code would cause our grep implementation to exit at the
first non-matching line:

@
      return $ if line =~ packedRe then [line] else []    -- Incorrect
@

(If you don't like this 'mempty'-means-EOF behavior, you can also wrap
the argument to 'mkInum' in the function 'whileNullI'.)

Now we are almost ready to assemble all the pieces.  But recall that
the '|$' operator applies one 'Onum' to one 'Iter', yet now we have
two 'Onum's (because we want to look through two files), and three
'Inum's that we want to compose into a pipeline.  The library
supports two types of composition for pipeline stages:
/concatenation/ and /fusing/.

Two 'Inum's (or 'Onum's) of the same type can be /concatenated/ with
the 'cat' function, producing a new data source that enumerates all of
the data in the first 'Inum' followed by all of the data in the
second.

There are two /fusing/ operators.  The left-associative '|.' operator
fuses two 'Inum's, provided the output type of the first is the input
type of the second.  (Mnemonic: it produces a pipeline stage that is
open on the right hand side, as it still needs to be applied to an
iteratee with '|$'.)  The right-associative '.|' operator fuses an
'Inum' to an 'Iter', producing a new 'Iter'.

The fusing operators bind more tightly than the infix concatenation
functions, which in turn bind more tightly than '|$'.  (Concatenation
operators can also be used through prefix function application, which
binds most tightly.)  Hence, putting it all together, we produce the
following Haskell equivalent to the above Unix pipeline:

@
    grepCount :: IO Int
    grepCount = 'enumFile' \"\/usr\/share\/dict\/words\" '|.' inumToLines
                    ``cat`` 'enumFile' \"\/usr\/share\/dict\/extra.words\" '|.' inumToLines
                '|$' inumGrep \"kk\"
                        '.|' inumGrep \"^[a-z]\"
                        '.|' lengthI
@

One often has a choice as to whether to fuse an 'Inum' to the
'Onum', or to the 'Iter'.  For example, @grepCount@ could
alternatively have been implemented as:

@
    grepCount' :: IO Int
    grepCount' = 'cat' ('enumFile' \"\/usr\/share\/dict\/words\" '|.' inumToLines)
                         ('enumFile' \"\/usr\/share\/dict\/extra.words\" '|.' inumToLines)
                    '|.' inumGrep \"kk\"
                    '|.' inumGrep \"^[a-z]\"
                 '|$' lengthI
@

In this case, the two are essentially equivalent.  However, for error
handling purposes, one should fuse together pipeline stages in which
errors have similar consequences.  Often an 'Inum' or 'Onum' failure
is less serious than an 'Iter' failure.  For example, in the above
example, if 'enumFile' fails because one of the files does not exist,
we might want to continue processing lines from the next file.
Conversely, if @lengthI@ fails or one of the @inumGrep@ stages fails
(most likely because the regular expression is illegal), there is not
much point in continuing the program.  This is why the first example
fused @inumGrep@ to @lengthI@, though this won't matter until we
actually handle errors (see below).

Another alternative would have been to swap the order of concatenation
and fusing:

@
    grepCount'' :: IO Int
    grepCount'' = 'cat' ('enumFile' \"\/usr\/share\/dict\/words\")
                           ('enumFile' \"\/usr\/share\/dict\/extra.words\")
                      '|.' inumToLines
                  '|$' inumGrep \"kk\"
                      '.|' inumGrep \"^[a-z]\"
                      '.|' lengthI
@

This last version changes the semantics of the counting slightly.
With @grepCount''@, if the first file has an incomplete last line,
this line will be merged with the first line of the second file, which
is probably not what you want.  (For instance, if the incomplete last
line of the first file starts with a capital letter, then the first
line of the second file will not be counted even if it starts with a
lower-case letter and contains two \"k\"s.)

One limitation of all the @grepCount@ variants shown so far is that if
the first file does not exist, the whole operation aborts.  This
might or might not be reasonable when counting lines, but in other
contexts we may want to resume after failure.  Suppose we want to
implement a function like the Unix @grep@ command that searches for a
string in a bunch of files and prints all matching lines.  If opening
or reading a file produces an error, the function should print the
error message and continue on with the next file.

Error handling is provided by the 'catchI' and 'inumCatch' functions,
which are roughly equivalent to the standard library @'catch'@
function.  There is also a 'throwI' function analogous to @'throwIO'@
in the standard library.  Because @'catch'@ only works in the IO
monad, 'catchI' and 'inumCatch' work by propagating synchronous
exceptions through the 'Iter' monad.  @'liftIO'@ transforms IO errors
into such synchronous exceptions.  Unfortunately, there is no way to
handle asynchronous exceptions such as those that arise in lazily
evaluated pure code (e.g., divide by zero) or those thrown by another
thread using @'throwTo'@.  Fortunately, for our @grep@ example, we
only need to catch IO errors.

Here is the @grep@ code.  We will analyze it below.

@
    grep :: String -> [FilePath] -> IO ()
    grep re files
        | null files = 'enumStdin' '|.' inumToLines '|$' inumGrep re '.|' linesOutI
        | otherwise  = foldr1 'cat' (map enumLines files) '|$' inumGrep re '.|' linesOutI
        where
          enumLines file = 'inumCatch' ('enumFile' file '|.' inumToLines) handler
          handler :: 'IOError'
                  -> 'IterR' () IO ('IterR' [S.ByteString] IO a)
                  -> 'Iter' () IO ('IterR' [S.ByteString] IO a)
          handler e result = do
            liftIO (hPutStrLn stderr $ show e)
            'resumeI' result
          linesOutI = do
            mline <- 'safeHeadI'
            case mline of
              Just line -> do liftIO $ S.putStrLn line
                              linesOutI
              Nothing -> return ()
@

There are two cases.  If the list of files to search is null, @grep@
simply reads from standard input, in which case there is only one
input stream and we do not care about resuming.  In the second case,
we use @'foldr1' 'cat'@ to concatenate a list of 'Onum's.  Each 'Onum'
is generated by the function @enumLines@, which fuses 'enumFile' to
our previously defined @inumToLines@, but also wraps the exception
handler function @handler@ around the enumerator using 'inumCatch'.

Note that unlike @catch@, 'inumCatch' expects an exception handler to
have /two/ arguments.  The first argument, @e@ in this example, is the
exception itself.  As with @catch@, the type of @e@ determines which
exceptions are caught, which is why we must either specify an explicit
type signature for @handler@ or somewhere specify @e@'s type
explicitly, for instance with:

>          ...
>            liftIO (hPutStrLn stderr $ show (e :: IOError))
>          ...

Note that 'IOError' doesn't expose a type constructor, but for
exception types that do, it often suffices to define the function with
the exception constructor, as:

>          handler e@(SomeException _) result = do ...

The second argument to @handler@, @result@, is the failed state of the
iteratee, which contains more information than just the exception.  In
the case of an 'Inum' failure, it contains the state of the 'Iter'
that the 'Inum' was feeding when it failed.  The type of 'result' is
'IterR'--which is the type returned by 'Iter's when they are fed
chunks of data.  'IterR' takes the same three type arguments as
'Iter'.  The function 'resumeI' extracts and returns an @'Iter'
[S.ByteString] IO a@ from this failed result.  Thus, the next
enumerator in a concatenated series can continue feeding it input.
If, instead of resuming, you want to re-throw the error, it suffices
to re-execute the failed result with @'reRunIter'@.  For instance,
suppose we want to continue executing @grep@ when a named file does
not exist, but if some other error happens, we want to re-throw the
exception to abort the whole program.  This could be achieved as
follows:

>          handler e result = do
>            if isDoesNotExistError e
>              then do liftIO (hPutStrLn stderr $ show e)
>                      resumeI result
>              else reRunIter result

Because printing an exception is so common, there is a function
'verboseResumeI' that prints exceptions before resuming (also
prefixing the program name).  Thus, we can simplify the above function
to:

>          handler e result = if isDoesNotExistError e
>                               then verboseResumeI result
>                               else reRunIter result

These last two @handler@ functions also do away with the need for an
explicit type signature, because the function @'isDoesNotExistError'@
has argument type 'IOError', constraining the type of @e@ to the type
of exceptions we want to catch.

-}

{- $Differences

The Iteratee approach was originally advocated by Oleg Kiselyov (see
talk slides at <http://okmij.org/ftp/Streams.html#iteratee>).  The
main implementation by Kiselyov and John Lato is simply called
/iteratee/ (<http://hackage.haskell.org/package/iteratee>).  Another
attempt to simplify the iteratee concepts was the /enumerator/ package
(<http://hackage.haskell.org/package/enumerator>).  IterIO is a
re-implementation of these concepts from scratch.  This section
discusses the differences between previous packages and iterIO.

* /Base abstraction:/

The iterIO package represents an iteratee as a pure function from a
chunk of input data to a pure iteratee result of type 'IterR':

@
  newtype 'Iter' t m a = 'Iter' { runIter :: 'Chunk' t -> 'IterR' t m a }
@

An 'IterR' can yield a result and residual input, or it can ask for
more input, or it can request to have an action executed in the
underlying monad, or it can signal failure.  This structure guarantees
that an iteratee has access to all pending input, which makes it
possible to do things like flush the input stream when seeking in a
file, or measure the length of buffered input when determining the
current position in a file.  Moreover, one can distinguish at runtime
between pure iteratees and those that require monadic actions; this
ability in many cases allows one to parse LL(*) grammars without
needing unbounded buffering for rollback (see below).

In contrast, the iteratee package uses continuation passing style
(CPS), in which an iteratee is a function taking two continuation
functions--one to call when done, and a second to call when either
requesting more input or failing:

> -- From the iteratee package:
> newtype Iteratee s m a = Iteratee{ runIter :: forall r.
>           (a -> Stream s -> m r) ->
>           ((Stream s -> Iteratee s m a) -> Maybe SomeException -> m r) ->
>           m r}

CPS has the advantage of exposing the bind operator of the underlying
mondad, making 'lift' cheap and simple.  Moreover, splitting into two
continuations saves the first (i.e., \"onDone\") continuation from the
overhead of checking whether an error condition or request for more
input has occurred.  See
<http://haskell.org/haskellwiki/Performance/Monads#Use__Continuation_Passing_Style>
for a good discussion of the advantages of CPS.

However, iteratee lacks several features of iterIO; offering these
features would reduce the benefits of CPS and complicate code.  For
instance, there is no way to execute a pure iteratee without monadic
actions (a highly useful feature for LL(*) parsing).  Moreover,
iteratee's exception mechanism discards the current location in the
input stream, making it unsuitable for failed parse alternatives.
IterIO provides a general control mechanism to make arbitrary requests
from enumerators (such as seek, tell, getpeername, get SSL
information, etc.); iteratee instead overloads the exception mechanism
for control messages, which prevents control operations from returning
values.  Thus, while iteratee can implement seek, it cannot, for
instance, implement tell.

The enumerator package's approach is closer to iterIO's, but makes
every iteratee into a monadic computation:

> -- From the enumerator package:
> newtype Iteratee a m b = Iteratee { runIteratee :: m (Step a m b) }

Here @Step@ is similar to iterIO's 'IterR' type, but the @m@ wrapper
disallows iterIO's LL(*) parsing tricks.  It also causes gratuitous
invocation of @m@'s bind function, which can be expensive when using
stacks of monad transformers.  Furthermore, enumerator discards the
input state on all errors, making it impossible to resume from a parse
error.

* /Uniformity of abstraction/

The iterIO package's abstractions were carefully crafted to be minimal
yet highly expressive and familiar to Unix command-shell users.  Thus,
we have 'Iter's, which are data sinks that consume input and produce a
result.  Then we have 'Inum's, which are also 'Iter's.  These two data
types and can combined through pipes (i.e., fusing) and concatenation,
both of which should be intuitive to Unix command-line users.

Basing everything around these few concepts makes the library easier
to learn and use.  For instance, because all 'Inum's are 'Iter's,
there is only one set of 'Iter' building blocks to learn.  'Inum'
implementations invoke the same 'Iter's that are used to consume data
in data sinks.  Moreover, 'Inum's use the same error handling
mechanism as 'Iter's.  Finally, because 'Onum's are also 'Inum's, one
set of fusing and concatenation operators works with both.

By contrast, both the iteratee and enumerator packages use enumerator
types that are not iteratees.  Hence constructing enumerators is
harder and requires a different error handing mechanism.  The packages
must introduce a third, hybrid \"Enumeratee\" type for inner pipeline
stages, and fusing Enumerators to Enumeratees is a different function
from fusing Enumeratees together.

* /Uniform error-handling and simplified monad transformers/

The iterIO library provides a traditional throw and catch exception
mechanism supporting the standard library exception hierarchy from
"Control.Exception".  However, all of the support routines are
carefully crafted to ensure that this single exception mechanism is
the only one you ever need, so that you don't end up having to
integrate different components with different error strategies, a
situation summarized amusingly in the following blog post:
<http://www.randomhacks.net/articles/2007/03/10/haskell-8-ways-to-report-errors>.

A key to uniform error handling is ensuring that errors can be
propagated cleanly across different monads and transformers.  Thus,
for instance, the iterIO 'liftIO' function translates all uncaught IO
errors into 'Iter' errors.

More importantly, iterIO is designed to support all the standard mtl
monad transformers while keeping 'Iter' as the outermost monadic type.
For instance, if deep in the middle of some @'Iter' t 'IO'@
computation you really need a state transformer monad, you can invoke
one with 'runStateTI', which is the iterIO equivalent of 'runStateT'.
As seen by comparing their effective types, 'runStateTI' manages to
keep the 'Iter' monad on the outside, and thus can cleanly propagate
failures out of the 'StateT' subcomputation:

> runStateT  :: StateT s m a -> s -> m (a, s)
>
> runStateTI :: Iter t (StateT s m) a -> s -> Iter t m (a, s)

Similarly, there is a function @'liftIterM' :: (MonadTrans t) => Iter
s m a -> Iter s (t m) a@ that can be used to execute a computation in
which a level of monad transformer is stripped off the inner monadic
type.

An equally important feature is the ability to distinguish 'Iter'
failures from 'Inum' failures, given that the former are often more
serious than the latter.  As shown by the @grep@ example in the
tutorial above, when one in a series of concatenated 'Inum's fail, you
sometimes want to keep going without losing the state of the 'Iter'.
The enumeratee package does not appear to support this distinction.
The iteratee package might, but it is not clear how to implement
@grep@ from above.

By contrast, iterIO's 'Inum' failure should be intuitive.  If you wrap
a pipeline of 'Inum's in an 'inumCatch' statement, then you will catch
exactly the errors thrown by those 'Inum's, not those thrown by
pipeline stages to either side of the 'inumCatch' call.

* /Parser combinators for LL(*) grammars/


-}

{- $Acknowledgments

Daniel Giffin contributed numerous suggestions and improvements to
both the code and documentation.  Deian Stefan and David Terei helped
with testing and improving the package, as well as understanding
various relevant aspects of Haskell and ghc.

The author is also grateful to John Lato for helping him understand
much of the important design rationale behind the original iteratee
package.

This work was funded by the DARPA Clean-Slate Design of Resilient,
Adaptive, Secure Hosts (CRASH) program, BAA-10-70.

-}
