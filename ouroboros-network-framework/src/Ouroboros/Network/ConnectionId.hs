{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}

module Ouroboros.Network.ConnectionId
  ( ConnectionId
  , ConnectionId' (..)
  , knownRemoteAddress
  , WithConnectionId
  , WithConnectionId' (..)
  , MaybeAddress (..)
  , withKnownRemoteAddress
  ) where

import           Cardano.Prelude (NoUnexpectedThunks (..), Generic,
                   UseIsNormalForm (..))

-- | Connection is identified by local and remote address.
--
-- There are cases where we don't know the remote address, for that reason we
-- let the local and remote addresses vary.
--
-- TODO: the type variable which this data type fills in is called `peerid`.  We
-- should renamed to `connectionId`.
--
data ConnectionId' localAddr remoteAddr = ConnectionId {
    localAddress  :: !localAddr,
    remoteAddress :: !remoteAddr
  }
  deriving (Eq, Ord, Show, Generic)
  deriving NoUnexpectedThunks via (UseIsNormalForm (ConnectionId' localAddr remoteAddr))


-- | Placeholder when we don't know the address, e.g. when accept loop errors we
-- might not know the remote address.
--
data MaybeAddress addr
    = UnknownAddress
    | KnownAddress !addr
  deriving (Eq, Ord)

instance Show addr => Show (MaybeAddress addr) where
    show UnknownAddress      = "UnknownAddress"
    show (KnownAddress addr) = show addr


knownRemoteAddress :: ConnectionId addr -> ConnectionId' addr (MaybeAddress addr)
knownRemoteAddress ConnectionId { localAddress, remoteAddress } =
    ConnectionId {
        localAddress,
        remoteAddress = KnownAddress remoteAddress
      }

type ConnectionId addr = ConnectionId' addr addr

-- | Tracing context.
--
data WithConnectionId' localAddr remoteAddr a = WithConnectionId {
    wcConnectionId :: !(ConnectionId' localAddr remoteAddr),
    wcEvent        :: !a
  }
  deriving Show
  deriving NoUnexpectedThunks via (UseIsNormalForm (WithConnectionId' localAddr remoteAddr a))

type WithConnectionId addr = WithConnectionId' addr addr


withKnownRemoteAddress :: WithConnectionId addr a
                       -> WithConnectionId' addr (MaybeAddress addr) a
withKnownRemoteAddress WithConnectionId { wcConnectionId, wcEvent } =
    WithConnectionId {
        wcConnectionId = knownRemoteAddress wcConnectionId,
        wcEvent
      }
