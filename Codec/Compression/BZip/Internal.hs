-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) 2006-2007 Duncan Coutts
-- License     :  BSD-style
--
-- Maintainer  :  duncan.coutts@worc.ox.ac.uk
-- Stability   :  provisional
-- Portability :  portable (H98 + FFI)
--
-- Pure stream based interface to lower level bzlib wrapper
--
-----------------------------------------------------------------------------
module Codec.Compression.BZip.Internal (

  -- * Compression and decompression
  compressDefault,
  decompressDefault,
  Stream.BlockSize(..),

  -- * The same but with the full set of parameters
  compressFull,
  decompressFull,
  Stream.WorkFactor(..),
  Stream.MemoryLevel(..),
  Stream.Verbosity(..),

  ) where

import Prelude hiding (length)
import Control.Monad (when)
import Control.Exception (assert)
import qualified Data.ByteString.Lazy as L
#ifdef BYTESTRING_IN_BASE
import qualified Data.ByteString.Base as S
#else
import qualified Data.ByteString.Lazy.Internal as L
import qualified Data.ByteString.Internal as S
#endif

import qualified Codec.Compression.BZip.Stream as Stream
import Codec.Compression.BZip.Stream (Stream)

compressDefault
  :: Stream.BlockSize
  -> L.ByteString
  -> L.ByteString
compressDefault blockSize =
  compressFull blockSize
               Stream.Silent
               Stream.DefaultWorkFactor

decompressDefault
  :: L.ByteString
  -> L.ByteString
decompressDefault =
  decompressFull Stream.Silent
                 Stream.DefaultMemoryLevel

{-# NOINLINE compressFull #-}
compressFull
  :: Stream.BlockSize
  -> Stream.Verbosity
  -> Stream.WorkFactor
  -> L.ByteString
  -> L.ByteString
compressFull blockSize verbosity workFactor input =
  L.fromChunks $ Stream.run $ do
    Stream.compressInit blockSize verbosity workFactor
    case L.toChunks input of
      [] -> fillBuffers []
      S.PS inFPtr offset length : chunks -> do
        Stream.pushInputBuffer inFPtr offset length
        fillBuffers chunks

  where
#ifdef BYTESTRING_IN_BASE
  outChunkSize = 16 * 1024 - 16
#else
  outChunkSize = 32 * 1024 - L.chunkOverhead
#endif

    -- we flick between two states:
    --   * where one or other buffer is empty
    --       - in which case we refill one or both
    --   * where both buffers are non-empty
    --       - in which case we compress until a buffer is empty

  fillBuffers ::
      [S.ByteString]
   -> Stream [S.ByteString]
  fillBuffers inChunks = do
    Stream.consistencyCheck

    -- in this state there are two possabilities:
    --   * no outbut buffer space is available
    --       - in which case we must make more available
    --   * no input buffer is available
    --       - in which case we must supply more
    inputBufferEmpty <- Stream.inputBufferEmpty
    outputBufferFull <- Stream.outputBufferFull

    assert (inputBufferEmpty || outputBufferFull) $ return ()

    when outputBufferFull $ do
      outFPtr <- Stream.unsafeLiftIO (S.mallocByteString outChunkSize)
      Stream.pushOutputBuffer outFPtr 0 outChunkSize

    if inputBufferEmpty
      then case inChunks of
             [] -> drainBuffers []
             S.PS inFPtr offset length : inChunks' -> do
                Stream.pushInputBuffer inFPtr offset length
                drainBuffers inChunks'
      else drainBuffers inChunks


  drainBuffers ::
      [S.ByteString]
   -> Stream [S.ByteString]
  drainBuffers inChunks = do

    inputBufferEmpty' <- Stream.inputBufferEmpty
    outputBufferFull' <- Stream.outputBufferFull
    assert(not outputBufferFull'
       && (null inChunks || not inputBufferEmpty')) $ return ()
    -- this invariant guarantees we can always make forward progress

    let action = if null inChunks then Stream.Finish else Stream.Run
    status <- Stream.compress action

    case status of
      Stream.Ok -> do
        outputBufferFull <- Stream.outputBufferFull
        if outputBufferFull
          then do (outFPtr, offset, length) <- Stream.popOutputBuffer
                  outChunks <- Stream.unsafeInterleave (fillBuffers inChunks)
                  return (S.PS outFPtr offset length : outChunks)
          else do fillBuffers inChunks

      Stream.StreamEnd -> do
        inputBufferEmpty <- Stream.inputBufferEmpty
        assert inputBufferEmpty $ return ()
        outputBufferBytesAvailable <- Stream.outputBufferBytesAvailable
        if outputBufferBytesAvailable > 0
          then do (outFPtr, offset, length) <- Stream.popOutputBuffer
                  Stream.finalise
                  return [S.PS outFPtr offset length]
          else do Stream.finalise
                  return []


{-# NOINLINE decompressFull #-}
decompressFull
  :: Stream.Verbosity
  -> Stream.MemoryLevel
  -> L.ByteString
  -> L.ByteString
decompressFull verbosity memLevel input =
  L.fromChunks $ Stream.run $ do
    Stream.decompressInit verbosity memLevel
    case L.toChunks input of
      [] -> fillBuffers []
      S.PS inFPtr offset length : chunks -> do
        Stream.pushInputBuffer inFPtr offset length
        fillBuffers chunks

  where
  outChunkSize :: Int
#ifdef BYTESTRING_IN_BASE
  outChunkSize = 16 * 1024 - 16
#else
  outChunkSize = 32 * 1024 - L.chunkOverhead
#endif

    -- we flick between two states:
    --   * where one or other buffer is empty
    --       - in which case we refill one or both
    --   * where both buffers are non-empty
    --       - in which case we compress until a buffer is empty

  fillBuffers ::
      [S.ByteString]
   -> Stream [S.ByteString]
  fillBuffers inChunks = do

    -- in this state there are two possabilities:
    --   * no outbut buffer space is available
    --       - in which case we must make more available
    --   * no input buffer is available
    --       - in which case we must supply more
    inputBufferEmpty <- Stream.inputBufferEmpty
    outputBufferFull <- Stream.outputBufferFull

    assert (inputBufferEmpty || outputBufferFull) $ return ()

    when outputBufferFull $ do
      outFPtr <- Stream.unsafeLiftIO (S.mallocByteString outChunkSize)
      Stream.pushOutputBuffer outFPtr 0 outChunkSize

    if inputBufferEmpty
      then case inChunks of
             [] -> drainBuffers []
             S.PS inFPtr offset length : inChunks' -> do
                Stream.pushInputBuffer inFPtr offset length
                drainBuffers inChunks'
      else drainBuffers inChunks


  drainBuffers ::
      [S.ByteString]
   -> Stream [S.ByteString]
  drainBuffers inChunks = do

    inputBufferEmpty' <- Stream.inputBufferEmpty
    outputBufferFull' <- Stream.outputBufferFull
    assert(not outputBufferFull'
       && (null inChunks || not inputBufferEmpty')) $ return ()
    -- this invariant guarantees we can always make forward progress or at
    -- least detect premature EOF

    status <- Stream.decompress

    case status of
      Stream.Ok -> do
        outputBufferFull <- Stream.outputBufferFull
        if outputBufferFull
          then do (outFPtr, offset, length) <- Stream.popOutputBuffer
                  outChunks <- Stream.unsafeInterleave (fillBuffers inChunks)
                  return (S.PS outFPtr offset length : outChunks)
          else do -- We need to detect if we ran out of input:
                  inputBufferEmpty <- Stream.inputBufferEmpty
                  if inputBufferEmpty && null inChunks
                    then fail "premature end of compressed stream"
                    else fillBuffers inChunks

      Stream.StreamEnd -> do
        -- Note that there may be input bytes still available if the stream
        -- is embeded in some other data stream. Here we just silently discard
        -- any trailing data.
        outputBufferBytesAvailable <- Stream.outputBufferBytesAvailable
        if outputBufferBytesAvailable > 0
          then do (outFPtr, offset, length) <- Stream.popOutputBuffer
                  Stream.finalise
                  return [S.PS outFPtr offset length]
          else do Stream.finalise
                  return []
