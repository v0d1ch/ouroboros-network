-- Common things between P2P and NonP2P Diffusion modules

module Ouroboros.Network.Diffusion.Common
  ( DiffusionInitializationTracer(..)
  , DiffusionFailure(..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Ouroboros.Network.NodeToClient (LocalAddress)
import Network.Socket (SockAddr)
import Ouroboros.Network.Snocket (FileDescriptor)
import Control.Exception (SomeException, Exception)


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

