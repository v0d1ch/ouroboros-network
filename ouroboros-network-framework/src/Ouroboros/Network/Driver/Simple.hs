{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE FlexibleContexts #-}
-- @UndecidableInstances@ extensions is required for defining @Show@ instance
-- of @'TraceSendRecv'@.
{-# LANGUAGE UndecidableInstances #-}

-- | Drivers for running 'Peer's with a 'Codec' and a 'Channel'.
--
module Ouroboros.Network.Driver.Simple (

  -- * Introduction
  -- $intro

  -- * Normal peers
  runPeer,
  TraceSendRecv(..),
  DecoderFailure(..),

  -- * Connected peers
  -- TODO: move these to a test lib
  runConnectedPeers,
  runConnectedPeersAsymmetric,
  ) where

import Data.Singletons

import Network.TypedProtocol.Core
import Network.TypedProtocol.Codec
import Network.TypedProtocol.Driver
import Network.TypedProtocol.Peer

import Ouroboros.Network.Util.ShowProxy

import Ouroboros.Network.Channel

import Control.Monad.Class.MonadSTM
import Control.Monad.Class.MonadAsync
import Control.Monad.Class.MonadThrow
import Control.Tracer (Tracer (..), traceWith, contramap)


-- $intro
--
-- A 'Peer' is a particular implementation of an agent that engages in a
-- typed protocol. To actualy run one we need a source and sink for the typed
-- protocol messages. These are provided by a 'Channel' and a 'Codec'. The
-- 'Channel' represents one end of an untyped duplex message transport, and
-- the 'Codec' handles conversion between the typed protocol messages and
-- the untyped channel.
--
-- So given the 'Peer' and a compatible 'Codec' and 'Channel' we can run the
-- peer in some appropriate monad. The peer and codec have to agree on
-- the same protocol and role in that protocol. The codec and channel have to
-- agree on the same untyped medium, e.g. text or bytes. All three have to
-- agree on the same monad in which they will run.
--
-- This module provides drivers for normal and pipelined peers. There is
-- very little policy involved here so typically it should be possible to
-- use these drivers, and customise things by adjusting the peer, or codec
-- or channel.
--
-- It is of course possible to write custom drivers and the code for these ones
-- may provide a useful starting point. The 'runDecoder' function may be a
-- helpful utility for use in custom drives.
--

-- | Structured 'Tracer' output for 'runPeer' and derivitives.
--
data TraceSendRecv ps where
     TraceSendMsg :: AnyMessage ps -> TraceSendRecv ps
     TraceRecvMsg :: AnyMessage ps -> TraceSendRecv ps

instance Show (AnyMessage ps) => Show (TraceSendRecv ps) where
  show (TraceSendMsg msg) = "Send " ++ show msg
  show (TraceRecvMsg msg) = "Recv " ++ show msg


data DecoderFailure where
    DecoderFailure :: forall ps (st :: ps) failure.
                      ( Show failure
                      , Show (Sing st)
                      , ShowProxy ps
                      )
                   => SingPeerHasAgency st
                   -> failure
                   -> DecoderFailure

instance Show DecoderFailure where
    show (DecoderFailure (tok :: SingPeerHasAgency (st :: ps)) failure) =
      concat
        [ "DecoderFailure ("
        , showProxy (Proxy :: Proxy ps)
        , ") "
        , show tok
        , ") ("
        , show failure
        , ")"
        ]

instance Exception DecoderFailure where


driverSimple :: forall ps (pr :: PeerRole) failure bytes m.
                ( MonadThrow m
                , Exception failure
                )
             => Tracer m (TraceSendRecv ps)
             -> Codec ps failure m bytes
             -> Channel m bytes
             -> Driver ps pr bytes failure (Maybe bytes) m
driverSimple tracer Codec{encode, decode} channel@Channel{send} =
    Driver { sendMessage, recvMessage, tryRecvMessage, startDState = Nothing }
  where
    sendMessage :: forall (st :: ps) (st' :: ps).
                   SingI (PeerHasAgency st)
                => (ReflRelativeAgency (StateAgency st)
                                        WeHaveAgency
                                       (Relative pr (StateAgency st)))
                -> Message ps st st'
                -> Maybe bytes
                -> m (Maybe bytes)
    sendMessage _ msg dstate = do
      send (encode msg)
      traceWith tracer (TraceSendMsg (AnyMessage msg))
      return dstate

    recvMessage :: forall (st :: ps).
                   SingI (PeerHasAgency st)
                => (ReflRelativeAgency (StateAgency st)
                                        TheyHaveAgency
                                       (Relative pr (StateAgency st)))
                -> Either ( DecodeStep bytes failure m (SomeMessage st)
                          , Maybe bytes
                          )
                          (Maybe bytes)
                -> m (SomeMessage st, Maybe bytes)
    recvMessage _ state = do
      result  <- case state of
        Left (decoder, trailing) ->
          runDecoderWithChannel channel trailing decoder
        Right trailing ->
          runDecoderWithChannel channel trailing =<< decode
      case result of
        Right x@(SomeMessage msg, _trailing') -> do
          traceWith tracer (TraceRecvMsg (AnyMessage msg))
          return x
        Left failure ->
          throwIO failure

    tryRecvMessage :: forall (st :: ps).
                      SingI (PeerHasAgency st)
                   => (ReflRelativeAgency (StateAgency st)
                                           TheyHaveAgency
                                          (Relative pr (StateAgency st)))
                   -> Either ( DecodeStep bytes failure m (SomeMessage st)
                             , Maybe bytes
                             )
                             (Maybe bytes)
                   -> m (Either ( DecodeStep bytes failure m (SomeMessage st)
                                , Maybe bytes
                                )
                                (SomeMessage st, Maybe bytes))
    tryRecvMessage _ state = do
      result <-
        case state of
          Left (decoder, trailing) ->
            tryRunDecoderWithChannel channel trailing decoder
          Right trailing ->
            tryRunDecoderWithChannel channel trailing =<< decode
      case result of
        Right x@(Right (SomeMessage msg, _trailing')) -> do
          traceWith tracer (TraceRecvMsg (AnyMessage msg))
          return x
        Right x@Left {} ->
          return x
        Left failure ->
          throwIO failure


-- | Run a peer with the given channel via the given codec.
--
-- This runs the peer to completion (if the protocol allows for termination).
--
runPeer
  :: forall ps (st :: ps) pr pl failure bytes m a .
     (MonadThrow m, Exception failure)
  => Tracer m (TraceSendRecv ps)
  -> Codec ps failure m bytes
  -> Channel m bytes
  -> Peer ps pr pl Empty st m a
  -> m (a, Maybe bytes)
runPeer tracer codec channel peer =
    runPeerWithDriver driver peer (startDState driver)
  where
    driver = driverSimple tracer codec channel


--
-- Utils
--

-- | Run a codec incremental decoder 'DecodeStep' against a channel. It also
-- takes any extra input data and returns any unused trailing data.
--
runDecoderWithChannel :: Monad m
                      => Channel m bytes
                      -> Maybe bytes
                      -> DecodeStep bytes failure m a
                      -> m (Either failure (a, Maybe bytes))

runDecoderWithChannel Channel{recv} = go
  where
    go _ (DecodeDone x trailing) = return (Right (x, trailing))
    go _ (DecodeFail failure)    = return (Left failure)
    go Nothing         (DecodePartial k) = recv >>= k        >>= go Nothing
    go (Just trailing) (DecodePartial k) = k (Just trailing) >>= go Nothing


-- | Like 'runDecoderWithChannel' but it is only using 'tryRecv', and returns
-- either when we decoding finished, errored or 'tryRecv' returned 'Nothing'.
--
tryRunDecoderWithChannel :: Monad m
                         => Channel m bytes
                         -> Maybe bytes
                         -> DecodeStep bytes failure m a
                         -> m (Either failure
                                (Either ( DecodeStep bytes failure m a
                                        , Maybe bytes
                                        )
                                        (a, Maybe bytes)))
tryRunDecoderWithChannel Channel{tryRecv} = go
  where
    go _ (DecodeDone x trailing) = return (Right (Right (x, trailing)))
    go _ (DecodeFail failure)    = return (Left failure)
    go dstate@Nothing d@(DecodePartial k) = do
      r <- tryRecv 
      case r of
        Nothing -> return (Right (Left (d, dstate)))
        Just m  -> k m >>= go Nothing
    go (Just trailing) (DecodePartial k) = k (Just trailing) >>= go Nothing


-- | Run two 'Peer's via a pair of connected 'Channel's and a common 'Codec'.
--
-- This is useful for tests and quick experiments.
--
-- The first argument is expected to create two channels that are connected,
-- for example 'createConnectedChannels'.
--
runConnectedPeers :: (MonadSTM m, MonadAsync m, MonadCatch m,
                      Exception failure)
                  => m (Channel m bytes, Channel m bytes)
                  -> Tracer m (PeerRole, TraceSendRecv ps)
                  -> Codec ps failure m bytes
                  -> Peer ps             pr  pl  Empty st m a
                  -> Peer ps (FlipAgency pr) pl' Empty st m b
                  -> m (a, b)
runConnectedPeers createChannels tracer codec client server =
    createChannels >>= \(clientChannel, serverChannel) ->

    (fst <$> runPeer tracerClient codec clientChannel client)
      `concurrently`
    (fst <$> runPeer tracerServer codec serverChannel server)
  where
    tracerClient = contramap ((,) AsClient) tracer
    tracerServer = contramap ((,) AsServer) tracer


-- Run the same protocol with different codes.  This is useful for testing
-- 'Hanshake' protocol which knows how to decode different versions.
--
runConnectedPeersAsymmetric
    :: ( MonadSTM m
       , MonadAsync m
       , MonadCatch m
       , Exception failure
       )
    => m (Channel m bytes, Channel m bytes)
    -> Tracer m (PeerRole, TraceSendRecv ps)
    -> Codec ps failure m bytes
    -> Codec ps failure m bytes
    -> Peer ps             pr  pl  Empty st m a
    -> Peer ps (FlipAgency pr) pl' Empty st m b
    -> m (a, b)
runConnectedPeersAsymmetric createChannels tracer codec codec' client server =
    createChannels >>= \(clientChannel, serverChannel) ->

    (fst <$> runPeer tracerClient codec  clientChannel client)
      `concurrently`
    (fst <$> runPeer tracerServer codec' serverChannel server)
  where
    tracerClient = contramap ((,) AsClient) tracer
    tracerServer = contramap ((,) AsServer) tracer
