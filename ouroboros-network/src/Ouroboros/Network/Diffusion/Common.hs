-- Common things between P2P and NonP2P Diffusion modules

module Ouroboros.Network.Diffusion.Common
  ( DiffusionInitializationTracer(..)
  , DiffusionFailure(..)
  , DiffusionTracers(..)
  , nullTracers
  ) where

import           Data.List.NonEmpty (NonEmpty)

import           Network.Socket (SockAddr)
import           Network.Mux (WithMuxBearer, MuxTrace)

import           Control.Exception (SomeException, Exception)
import           Control.Tracer (Tracer, nullTracer)

import           Ouroboros.Network.NodeToClient (LocalAddress)
import           Ouroboros.Network.Snocket (FileDescriptor)
import           Ouroboros.Network.PeerSelection.LedgerPeers (TraceLedgerPeers)
import           Ouroboros.Network.NodeToNode (ConnectionId)
import qualified Ouroboros.Network.NodeToNode as NodeToNode
import qualified Ouroboros.Network.NodeToClient as NodeToClient

-- TODO: use LocalAddress where appropriate rather than 'path'.
--
data DiffusionInitializationTracer
  = RunServer !(NonEmpty SockAddr)
  | RunLocalServer !LocalAddress
  | UsingSystemdSocket !FilePath
  -- Rename as 'CreateLocalSocket'
  | CreateSystemdSocketForSnocketPath !FilePath
  | CreatedLocalSocket !FilePath
  | ConfiguringLocalSocket !FilePath !FileDescriptor
  | ListeningLocalSocket !FilePath !FileDescriptor
  | LocalSocketUp  !FilePath !FileDescriptor
  -- Rename as 'CreateServerSocket'
  | CreatingServerSocket !SockAddr
  | ConfiguringServerSocket !SockAddr
  | ListeningServerSocket !SockAddr
  | ServerSocketUp !SockAddr
  -- Rename as 'UnsupportedLocalSocketType'
  | UnsupportedLocalSystemdSocket !SockAddr
  -- Remove (this is impossible case), there's no systemd on Windows
  | UnsupportedReadySocketCase
  | DiffusionErrored SomeException
    deriving Show

-- TODO: add a tracer for these misconfiguration
data DiffusionFailure = UnsupportedLocalSocketType
                      | UnsupportedReadySocket -- Windows only
                      | UnexpectedIPv4Address
                      | UnexpectedIPv6Address
                      | UnexpectedUnixAddress
                      | NoSocket
  deriving (Eq, Show)

instance Exception DiffusionFailure

-- | Common DiffusionTracers interface between P2P and NonP2P
--
data DiffusionTracers p2p = DiffusionTracers {
      -- | Mux tracer
      dtMuxTracer
        :: Tracer IO (WithMuxBearer (ConnectionId SockAddr) MuxTrace)

      -- | Handshake protocol tracer
    , dtHandshakeTracer
        :: Tracer IO NodeToNode.HandshakeTr

      --
      -- NodeToClient tracers
      --

      -- | Mux tracer for local clients
    , dtLocalMuxTracer
        :: Tracer IO (WithMuxBearer (ConnectionId LocalAddress) MuxTrace)

      -- | Handshake protocol tracer for local clients
    , dtLocalHandshakeTracer
        :: Tracer IO NodeToClient.HandshakeTr

      -- | Diffusion initialisation tracer
    , dtDiffusionInitializationTracer
        :: Tracer IO DiffusionInitializationTracer

      -- | Ledger Peers tracer
    , dtLedgerPeersTracer
        :: Tracer IO TraceLedgerPeers

      -- | P2P or NonP2P DiffusionTracers
    , dtP2P :: p2p
    }

nullTracers :: p2p -> DiffusionTracers p2p
nullTracers p2pNullTracers = DiffusionTracers {
  dtMuxTracer                       = nullTracer
  , dtHandshakeTracer               = nullTracer
  , dtLocalMuxTracer                = nullTracer
  , dtLocalHandshakeTracer          = nullTracer
  , dtDiffusionInitializationTracer = nullTracer
  , dtLedgerPeersTracer             = nullTracer
  , dtP2P                           = p2pNullTracers
  }
