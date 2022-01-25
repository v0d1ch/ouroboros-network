{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

-- | The type of the fast lane protocol,
-- used for diffusion pipelining via delayed validation.
module Ouroboros.Network.Protocol.FastLane.Type where

import           Data.Proxy (Proxy (..))

import           Network.TypedProtocol.Core (Protocol (..))

import           Ouroboros.Network.Util.ShowProxy (ShowProxy (..))

data FastLane header where

  -- | Both client and server are idle. The client can send a request and
  -- the server is waiting for a request.
  StIdle           :: FastLane header

  -- | The client has sent a request for a fast lane header, and is now waiting
  -- for the server to reply.
  StAwaitingHeader :: FastLane header

  -- | The terminal state.
  StDone           :: FastLane header

instance (ShowProxy header) => ShowProxy (FastLane header) where
  showProxy _ = concat
      [ "FastLane ("
      , showProxy (Proxy @header)
      , ")"
      ]

instance Protocol (FastLane header) where

  -- | The messages in the fast lane protocol.
  data Message (FastLane header) from to where

    -- | Request the most-desirable header of the server.
    MsgRequestNextFast :: Message (FastLane header)
                                  StIdle StAwaitingHeader

    -- | Send the most-desirable header to the client. The corresponding block
    -- is not guaranteed to have been validated or even selected.
    MsgFast :: header -> Message (FastLane header)
                                 StAwaitingHeader StIdle

    -- | Terminating message.
    MsgDone :: Message (FastLane header)
                       StIdle StDone

  data ClientHasAgency st where
    TokIdle           :: ClientHasAgency StIdle

  data ServerHasAgency st where
    TokAwaitingHeader :: ServerHasAgency StAwaitingHeader

  data NobodyHasAgency st where
    TokDone           :: NobodyHasAgency StDone

  exclusionLemma_ClientAndServerHaveAgency TokIdle = \case {}
  exclusionLemma_NobodyAndClientHaveAgency TokDone = \case {}
  exclusionLemma_NobodyAndServerHaveAgency TokDone = \case {}

instance (Show header) => Show (Message (FastLane header) from to) where
  show = \case
      MsgRequestNextFast -> "MsgRequestNextFast"
      MsgFast h          -> "MsgFast " ++ show h
      MsgDone            -> "MsgDone"
