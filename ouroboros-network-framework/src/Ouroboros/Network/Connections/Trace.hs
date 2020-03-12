{-# LANGUAGE BangPatterns   #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Tracing for applications that run on a connection.
--
module Ouroboros.Network.Connections.Trace
  ( ConnectionTrace (..)
  , WithAddr (..)
  ) where

import           Control.Exception
import           Text.Printf

-- | Trace for exceptions thrown either by application or by either `accept` or
-- `connect` system calls.
--
data ConnectionTrace =
    --  | Non-fatal exception raised by a mini-protocol.
    --
      ConnectionTraceApplicationException      !SomeException

    -- | Fatal exception to the network layer. It will be rethrown and the node
    -- (or client) will shout down.
    --
    | ConnectionTraceFatalApplicationException !SomeException

    -- | 'IOException' thrown by 'accept' call.
    --
    | ConnectionTraceAcceptException  !IOException

    -- | 'IOException' thrown by `connect` call.
    --
    | ConnectionTraceConnectException !IOException
  deriving Show


-- | 'WithAddr' tracing context for contravariant tracing.
--
data WithAddr addr a = WithAddr {
      wiaAddr  :: !addr
    , wiaEvent :: !a
    }


instance (Show addr, Show a) => Show (WithAddr addr a) where
    show WithAddr { wiaAddr, wiaEvent } =
        printf "IP %s %s" (show wiaAddr) (show wiaEvent)
