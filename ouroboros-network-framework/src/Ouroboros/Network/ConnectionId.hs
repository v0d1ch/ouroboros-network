{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveGeneric #-}

module Ouroboros.Network.ConnectionId
  ( ConnectionId (..)
  , WithConnectionId (..)
  ) where

import           Cardano.Prelude (NoUnexpectedThunks (..), Generic,
                   UseIsNormalForm (..))

-- | Connection is identified by local and remote address.
--
-- TODO: the type variable which this data type fills in is called `peerid`.  We
-- should renamed to `connectionId`.
--
data ConnectionId addr = ConnectionId {
    localAddress  :: !addr,
    remoteAddress :: !addr
  }
  deriving (Eq, Ord, Show, Generic)
  deriving NoUnexpectedThunks via (UseIsNormalForm (ConnectionId addr))


-- | Tracing context.
--
data WithConnectionId addr a = WithConnectionId {
    wcConnectionId :: !(ConnectionId addr),
    wcEvent        :: !a
  }
  deriving Show
