{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Drivers for running 'Peer's.
--
module Ouroboros.Network.Driver.Limits (

  -- * Limits
  ProtocolSizeLimits(..),
  ProtocolTimeLimits(..),
  ProtocolLimitFailure(..),

  -- * Normal peers
  runPeerWithLimits,
  TraceSendRecv(..),

  -- * Driver utilities
  driverWithLimits,
  ) where

import Data.Sequence.Strict (StrictSeq)
import qualified Data.Sequence.Strict as Seq
import Data.Singletons

import Control.Monad.Class.MonadAsync
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadSTM
import Control.Monad.Class.MonadThrow
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Tracer (Tracer (..), traceWith)

import Network.Mux.Timeout
import Network.TypedProtocol.Core
import Network.TypedProtocol.Codec
import Network.TypedProtocol.Driver
import Network.TypedProtocol.Peer

import Ouroboros.Network.Channel
import Ouroboros.Network.Driver.Simple (TraceSendRecv(..), DecoderFailure (..))
import Ouroboros.Network.Util.ShowProxy



data ProtocolSizeLimits ps bytes = ProtocolSizeLimits {
       sizeLimitForState :: forall (st :: ps).
                            SingPeerHasAgency st -> Word,

       dataSize          :: bytes -> Word
     }

data ProtocolTimeLimits ps = ProtocolTimeLimits {
       timeLimitForState :: forall  (st :: ps).
                            SingPeerHasAgency st -> Maybe DiffTime
     }

data ProtocolLimitFailure where
    ExceededSizeLimit :: forall ps (st :: ps).
                         ( Show (Sing st)
                         , ShowProxy ps
                         )
                      => SingPeerHasAgency st
                      -> ProtocolLimitFailure
    ExceededTimeLimit :: forall ps (st :: ps).
                         ( Show (Sing st)
                         , ShowProxy ps
                         )
                      => SingPeerHasAgency st
                      -> ProtocolLimitFailure

instance Show ProtocolLimitFailure where
    show (ExceededSizeLimit (stok :: SingPeerHasAgency (st :: ps))) =
      concat
        [ "ExceededSizeLimit ("
        , showProxy (Proxy :: Proxy ps)
        , ") ("
        , show stok
        , ")"
        ]
    show (ExceededTimeLimit (stok :: SingPeerHasAgency (st :: ps))) =
      concat
        [ "ExceededTimeLimit ("
        , showProxy (Proxy :: Proxy ps)
        , ") ("
        , show stok
        , ")"
        ]

instance Exception ProtocolLimitFailure where


data DState bytes =
    DState { dsTrailing  :: !(Maybe bytes)
           , dsTimeQueue :: !(StrictSeq Time)
             -- ^ times from which we start counting receiving a message.
             --
             -- TODO: document the logic!
           }


driverWithLimits :: forall ps (pr :: PeerRole) failure bytes m.
                    ( MonadThrow m
                    , MonadMonotonicTime m
                    , Exception failure
                    , ShowProxy ps
                    , forall (st' :: ps) tok. tok ~ Sing st' => Show tok
                    )
                 => Tracer m (TraceSendRecv ps)
                 -> TimeoutFn m
                 -> Codec ps failure m bytes
                 -> ProtocolSizeLimits ps bytes
                 -> ProtocolTimeLimits ps
                 -> Channel m bytes
                 -> Driver ps pr bytes failure (DState bytes) m
driverWithLimits tracer timeoutFn
                 Codec{encode, decode}
                 ProtocolSizeLimits{sizeLimitForState, dataSize}
                 ProtocolTimeLimits{timeLimitForState}
                 channel@Channel{send} =
    Driver { sendMessage, recvMessage, tryRecvMessage
           , startDState = DState Nothing Seq.empty }
  where
    sendMessage :: forall (st :: ps) (st' :: ps).
                   ( SingI (PeerHasAgency st)
                   , SingI (ProtocolState st')
                   )
                => (ReflRelativeAgency (StateAgency st)
                                        WeHaveAgency
                                       (Relative pr (StateAgency st)))
                -> Message ps st st'
                -> DState bytes
                -> m (DState bytes)
    sendMessage _ msg dstate = do
      send (encode msg)
      t <- getMonotonicTime
      traceWith tracer (TraceSendMsg (AnyMessage msg))
      -- we only append @t@ if msg shifted agency
      let dstate' = case ( phaAgency (sing @(PeerHasAgency st))
                         , psAgency (sing @(ProtocolState st'))
                         ) of
            (SingClientAgency, SingServerAgency)
              -> dstate { dsTimeQueue = dsTimeQueue dstate Seq.|> t
                        }
            (SingServerAgency, SingClientAgency)
              -> dstate { dsTimeQueue = dsTimeQueue dstate Seq.|> t
                        }
            _ -> dstate
      return dstate'

    recvMessage :: forall (st :: ps).
                   SingI (PeerHasAgency st)
                => (ReflRelativeAgency (StateAgency st)
                                        TheyHaveAgency
                                       (Relative pr (StateAgency st)))
                -> Either ( DecodeStep bytes failure m (SomeMessage st)
                          , DState bytes
                          )
                          (DState bytes)
                -> m (SomeMessage st, DState bytes)
    recvMessage _ state = do
      let tok = sing @(PeerHasAgency st)
          sizeLimit = sizeLimitForState tok
      t <- getMonotonicTime
      result <- case state of
        Left (decoder, dstate) ->
          case timeLimitFn t tok dstate of
            (Nothing,        _dstate') ->  return Nothing
            (Just timeLimit,  dstate') ->
              timeoutFn timeLimit $
                runDecoderWithLimit sizeLimit dataSize
                                    channel dstate' decoder
        Right dstate ->
          case timeLimitFn t tok dstate of
            (Nothing,        _dstate') -> return Nothing
            (Just timeLimit,  dstate') -> 
              timeoutFn timeLimit $
                runDecoderWithLimit sizeLimit dataSize
                                    channel dstate'    =<< decode
      case result of
        Just (Right (x@(SomeMessage (msg :: Message ps st st')), dstate)) -> do
          traceWith tracer (TraceRecvMsg (AnyMessage msg))
          t' <- getMonotonicTime
          let dstate' =
                case ( psAgency (sing @(ProtocolState st))
                     , psAgency (sing @(ProtocolState st'))
                     ) of
                  (SingClientAgency, SingServerAgency)
                    -> dstate { dsTimeQueue =           Seq.drop 1 (dsTimeQueue dstate) }
                  (SingServerAgency, SingClientAgency)
                    -> dstate { dsTimeQueue =           Seq.drop 1 (dsTimeQueue dstate) }
                  _ -> dstate { dsTimeQueue = t' Seq.<| Seq.drop 1 (dsTimeQueue dstate) }

          return (x, dstate')
        Just (Left (Just failure)) -> throwIO (DecoderFailure tok failure)
        Just (Left Nothing)        -> throwIO (ExceededSizeLimit tok)
        Nothing                    -> throwIO (ExceededTimeLimit tok)

    tryRecvMessage :: forall (st :: ps).
                      SingI (PeerHasAgency st)
                   => (ReflRelativeAgency (StateAgency st)
                                           TheyHaveAgency
                                          (Relative pr (StateAgency st)))
                   -> Either ( DecodeStep bytes failure m (SomeMessage st)
                             , DState bytes
                             )
                             (DState bytes)
                   -> m (Either ( DecodeStep bytes failure m (SomeMessage st)
                                , DState bytes
                                )
                                (SomeMessage st, DState bytes))
    tryRecvMessage _ state = do
      let tok = sing @(PeerHasAgency st)
          sizeLimit = sizeLimitForState tok
      t <- getMonotonicTime
      result <-
        case state of
          Left (decoder, dstate) ->
            case timeLimitFn t tok dstate of
              (Nothing,        _dstate') -> return Nothing
              (Just timeLimit,  dstate') ->
                timeoutFn timeLimit $
                tryRunDecoderWithLimit sizeLimit dataSize
                                       channel dstate' decoder
          Right dstate ->
            case timeLimitFn t tok dstate of
              (Nothing,        _dstate') -> return Nothing
              (Just timeLimit,  dstate') ->
                timeoutFn timeLimit $
                tryRunDecoderWithLimit sizeLimit dataSize
                                       channel dstate'    =<< decode
      case result of
        Just (Right (Right (x@(SomeMessage (msg :: Message ps st st')), dstate))) -> do
          traceWith tracer (TraceRecvMsg (AnyMessage msg))
          let dstate' =
                case ( psAgency (sing @(ProtocolState st))
                     , psAgency (sing @(ProtocolState st'))
                     ) of
                  (SingClientAgency, SingServerAgency)
                    -> dstate { dsTimeQueue =          Seq.drop 1 (dsTimeQueue dstate) }
                  (SingServerAgency, SingClientAgency)
                    -> dstate { dsTimeQueue =          Seq.drop 1 (dsTimeQueue dstate) }
                  _ -> dstate { dsTimeQueue = t Seq.<| Seq.drop 1 (dsTimeQueue dstate) }
          return (Right (x, dstate'))
        Just (Right x@Left {})     -> return x
        Just (Left (Just failure)) -> throwIO (DecoderFailure tok failure)
        Just (Left Nothing)        -> throwIO (ExceededSizeLimit tok)
        Nothing                    -> throwIO (ExceededTimeLimit tok)


    timeLimitFn :: forall (st :: ps).
                   Time
                -> SingPeerHasAgency st
                -> DState bytes
                -> (Maybe DiffTime, DState bytes)
    timeLimitFn t tok dstate =
      case (timeLimitForState tok, dstate) of

        (Nothing, DState _ (_ Seq.:<| _))
          -> (Just (-1), dstate)

        (Just timeLimit, DState _ (t' Seq.:<| _))
          -> let dstate' = dstate
                 timeLimit' = timeLimit - (t `diffTime` t')
                 -- if we are over time budget return Nothing.
             in
                ( if timeLimit' >= 0 then Just timeLimit' else Nothing
                , dstate'
                )

        -- this case corresponds to 'Await' which was not preceded with
        -- a 'Yield', i.e. a protocol starts with agency on the other side.
        (Nothing, DState _ Seq.Empty)
          -> (Just (-1),      dstate { dsTimeQueue = Seq.singleton t })

        (Just timeLimit, DState _ Seq.Empty)
          -> (Just timeLimit, dstate { dsTimeQueue = Seq.singleton t })


runDecoderWithLimit
    :: forall m bytes failure a. Monad m
    => Word
    -- ^ message size limit
    -> (bytes -> Word)
    -- ^ byte size
    -> Channel m bytes
    -> DState bytes
    -> DecodeStep bytes failure m a
    -> m (Either (Maybe failure) (a, DState bytes))
runDecoderWithLimit limit size Channel{recv} =
    go 0
  where
    -- Our strategy here is as follows...
    --
    -- We of course want to enforce the maximum data limit, but we also want to
    -- detect and report when we exceed the limit rather than having it be
    -- misclassified as a generic decode error. For example if we simply limited
    -- the decoder input to the maximum size then the failure would be reported
    -- as an unexpected end of input, rather than that the size limit was
    -- exceeded.
    --
    -- So our strategy is to allow the last chunk of input to exceed the limit.
    -- This leaves just one special case: if the decoder finishes with that
    -- final chunk, we must check if it consumed too much of the final chunk.
    --
    go :: Word         -- ^ size of consumed input so far
       -> DState bytes -- ^ any trailing data
       -> DecodeStep bytes failure m a
       -> m (Either (Maybe failure) (a, DState bytes))

    go !sz dstate (DecodeDone x trailing)
      | let sz' = sz - maybe 0 size trailing
      , sz' > limit = return (Left Nothing)
      | otherwise   = return (Right (x, dstate { dsTrailing = trailing }))

    go !_ _  (DecodeFail failure) = return (Left (Just failure))

    go !sz dstate@DState { dsTrailing } (DecodePartial k)
      | sz > limit = return (Left Nothing)
      | otherwise  = case dsTrailing of
                       Nothing -> do mbs <- recv
                                     let !sz' = sz + maybe 0 size mbs
                                         dstate' = dstate { dsTrailing = Nothing }
                                     go sz' dstate' =<< k mbs
                       Just bs -> do let sz' = sz + size bs
                                         dstate' = dstate { dsTrailing = Nothing }
                                     go sz' dstate' =<< k (Just bs)

tryRunDecoderWithLimit
  :: forall m bytes failure a. Monad m
  => Word
  -- ^ message size limit
  -> (bytes -> Word)
  -- ^ byte size
  -> Channel m bytes
  -> DState bytes
  -> DecodeStep bytes failure m a
  -> m (Either (Maybe failure)
               (Either ( DecodeStep bytes failure m a
                       , DState bytes
                       )
                       (a, DState bytes)))
tryRunDecoderWithLimit limit size Channel{tryRecv} =
    go 0
  where
    go :: Word         -- ^ size of consumed input so far
       -> DState bytes -- ^ any trailing data
       -> DecodeStep bytes failure m a
       -> m (Either (Maybe failure)
                    (Either ( DecodeStep bytes failure m a
                            , DState bytes
                            )
                            (a, DState bytes)))

    go !sz dstate (DecodeDone x trailing)
      | let sz' = sz - maybe 0 size trailing
      , sz' > limit = return (Left Nothing)
      | otherwise   = return (Right $ Right (x, dstate { dsTrailing = trailing }))

    go !_ _  (DecodeFail failure) = return (Left (Just failure))

    go !sz dstate d@(DecodePartial k)
      | sz > limit = return (Left Nothing)
      | otherwise  = case dsTrailing dstate of
                       Nothing -> do r <- tryRecv
                                     case r of
                                       Nothing -> return (Right (Left (d, dstate)))
                                       Just mbs ->
                                         let !sz' = sz + maybe 0 size mbs
                                         in k mbs
                                            >>= go sz' dstate { dsTrailing = Nothing }
                       Just bs -> do let sz' = sz + size bs
                                     k (Just bs)
                                       >>= go sz' dstate { dsTrailing = Nothing }

runPeerWithLimits
  :: forall ps (st :: ps) pr (pl :: Pipelined) failure bytes m a .
     ( MonadAsync m
     , MonadFork m
     , MonadMask m
     , MonadThrow (STM m)
     , MonadMonotonicTime m
     , MonadTimer m
     , forall (st' :: ps) stok. stok ~ Sing st' => Show stok
     , ShowProxy ps
     , Exception failure
     )
  => Tracer m (TraceSendRecv ps)
  -> Codec ps failure m bytes
  -> ProtocolSizeLimits ps bytes
  -> ProtocolTimeLimits ps
  -> Channel m bytes
  -> Peer ps pr pl Empty st m a
  -> m (a, Maybe bytes)
runPeerWithLimits tracer codec slimits tlimits channel peer =
    withTimeoutSerial $ \timeoutFn ->
      let driver = driverWithLimits tracer timeoutFn codec slimits tlimits channel
      in ( \ (a, DState { dsTrailing }) -> (a, dsTrailing))
         <$> runPeerWithDriver driver peer (startDState driver)
