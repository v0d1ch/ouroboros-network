{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
module Ouroboros.Network.Diffusion
  ( DiffusionTracers(..)
  , nullTracers
  , mkDiffusionTracersNonP2P
  , mkDiffusionTracersP2P
  , DiffusionArguments(..)
  , mkDiffusionArgumentsNonP2P
  , mkDiffusionArgumentsP2P
  , DiffusionApplications(..)
  , mkDiffusionApplicationsP2P
  , mkDiffusionApplicationsNonP2P
  , runDataDiffusion
  , LedgerPeersConsensusInterface (..)
  , daDiffusionMode
  , DiffusionInitializationTracer(..)
  , DiffusionFailure
  )
  where

import           Control.Monad.Class.MonadSTM (STM)
import           Data.ByteString.Lazy (ByteString)
import           Data.Void (Void)
import           Data.Map.Strict (Map)
import           Data.Time (DiffTime)
import           Control.Exception (IOException)
import           Control.Tracer (Tracer)

import           Network.Mux (WithMuxBearer, MuxTrace)
import           Network.Socket (SockAddr, Socket, AddrInfo)

import           Ouroboros.Network.NodeToNode
                 ( RemoteAddress
                 , NodeToNodeVersionData
                 , DiffusionMode
                 , NodeToNodeVersion
                 , MiniProtocolParameters
                 )
import qualified Ouroboros.Network.NodeToNode as NTN
import           Ouroboros.Network.NodeToClient
                 ( LocalAddress
                 , NodeToClientVersionData
                 , Versions
                 , ConnectionId
                 , NodeToClientVersion
                 )
import qualified Ouroboros.Network.NodeToClient as NTC

import           Ouroboros.Network.RethrowPolicy (RethrowPolicy)
import           Ouroboros.Network.BlockFetch (FetchMode)
import           Ouroboros.Network.Mux
                 ( Bundle
                 , MiniProtocol
                 , MuxMode (..)
                 , OuroborosApplication
                 , ControlMessage
                 )
import           Ouroboros.Network.PeerSelection.LedgerPeers
                 ( LedgerPeersConsensusInterface
                 , TraceLedgerPeers
                 , RelayAddress
                 , UseLedgerAfter
                 )
import           Ouroboros.Network.PeerSelection.PeerMetric (PeerMetrics)

import qualified Ouroboros.Network.Diffusion.Common as Common
import           Ouroboros.Network.Diffusion.Common
                 ( DiffusionInitializationTracer
                 , DiffusionFailure
                 )
import qualified Ouroboros.Network.Diffusion.P2P as P2P
import qualified Ouroboros.Network.Diffusion.NonP2P as NonP2P

newtype DiffusionTracers =
    DiffusionTracers
      (Common.DiffusionTracers
        (Either NonP2P.DiffusionTracers P2P.DiffusionTracers))

nullTracers :: Either NonP2P.DiffusionTracers P2P.DiffusionTracers
            -> DiffusionTracers
nullTracers p2pNullTracers = DiffusionTracers (Common.nullTracers p2pNullTracers)

-- | DiffusionArguments for either P2P or Non-P2P node
--
newtype DiffusionArguments m =
  DiffusionArguments (Either NonP2P.DiffusionArguments (P2P.DiffusionArguments m))

newtype DiffusionApplications ntnAddr ntcAddr ntnVersionData ntcVersionData m =
  DiffusionApplications
   (Either
    (NonP2P.DiffusionApplications ntnAddr ntcAddr ntnVersionData ntcVersionData m)
    (P2P.DiffusionApplications ntnAddr ntcAddr ntnVersionData ntcVersionData m)
   )

-- | Construct a value of NonP2P DiffusionArguments data type.
-- ouroboros-consensus needs access to this constructor so we export this
-- function in order to avoid exporting the P2P and NonP2P internal modules.
--
mkDiffusionArgumentsNonP2P
  :: Maybe (Either Socket AddrInfo)
  -> Maybe (Either Socket AddrInfo)
  -> Maybe (Either Socket FilePath)
  -> NonP2P.IPSubscriptionTarget
  -> [NonP2P.DnsSubscriptionTarget]
  -> NonP2P.AcceptedConnectionsLimit
  -> DiffusionMode
  -> DiffusionArguments m
mkDiffusionArgumentsNonP2P
  a1 a2 a3 a4 a5 a6 =
    DiffusionArguments
    . Left
    . NonP2P.DiffusionArguments
        a1 a2 a3 a4 a5 a6

-- | Construct a value of P2P DiffusionArguments data type.
-- ouroboros-consensus needs access to this constructor so we export this
-- function in order to avoid exporting the P2P and NonP2P internal modules.
--
mkDiffusionArgumentsP2P
  :: Maybe (Either Socket AddrInfo)
  -> Maybe (Either Socket AddrInfo)
  -> Maybe (Either Socket FilePath)
  -> NTN.PeerSelectionTargets
  -> STM m [(Int, Map RelayAddress NTN.PeerAdvertise)]
  -> STM m [RelayAddress]
  -> STM m UseLedgerAfter
  -> NonP2P.AcceptedConnectionsLimit
  -> DiffusionMode
  -> DiffTime
  -> DiffTime
  -> DiffusionArguments m
mkDiffusionArgumentsP2P
  a1 a2 a3 a4 a5 a6 a7 a8 a9
  a10 =
    DiffusionArguments
    . Right
    . P2P.DiffusionArguments
        a1 a2 a3 a4 a5 a6 a7 a8 a9
        a10

mkDiffusionApplicationsNonP2P
  :: Versions NodeToNodeVersion
             ntnVersionData
             (OuroborosApplication
                'ResponderMode
                ntnAddr
                ByteString
                m
                Void
                ())
  -> Versions
       NodeToNodeVersion
       ntnVersionData
       (OuroborosApplication 'InitiatorMode ntnAddr ByteString m () Void)
  -> Versions
       NodeToClientVersion
       ntcVersionData
       (OuroborosApplication 'ResponderMode ntcAddr ByteString m Void ())
  -> NTC.ErrorPolicies
  -> LedgerPeersConsensusInterface m
  -> DiffusionApplications
       ntnAddr ntcAddr ntnVersionData ntcVersionData m
mkDiffusionApplicationsNonP2P a1 a2 a3 a4 =
    DiffusionApplications
    . Left
    . NonP2P.DiffusionApplications
      a1 a2 a3 a4

-- | Construct a value of P2P DiffusionApplications data type.
-- ouroboros-consensus needs access to this constructor so we export this
-- function in order to avoid exporting the P2P and NonP2P internal modules.
--
mkDiffusionApplicationsP2P :: Versions
  NodeToNodeVersion
  ntnVersionData
  (Bundle
     (ConnectionId ntnAddr
      -> STM m ControlMessage
      -> [MiniProtocol 'InitiatorMode ByteString m () Void]))
  -> Versions
       NodeToNodeVersion
       ntnVersionData
       (Bundle
          (ConnectionId ntnAddr
           -> STM m ControlMessage
           -> [MiniProtocol 'InitiatorResponderMode ByteString m () ()]))
  -> Versions
       NodeToClientVersion
       ntcVersionData
       (OuroborosApplication 'ResponderMode ntcAddr ByteString m Void ())
  -> MiniProtocolParameters
  -> RethrowPolicy
  -> RethrowPolicy
  -> LedgerPeersConsensusInterface m
  -> PeerMetrics m ntnAddr
  -> STM m FetchMode
  -> DiffusionApplications
       ntnAddr ntcAddr ntnVersionData ntcVersionData m
mkDiffusionApplicationsP2P
  a1 a2 a3 a4 a5 a6 a7 a8 =
    DiffusionApplications
    . Right
    . P2P.DiffusionApplications
          a1 a2 a3 a4 a5 a6 a7 a8

-- | Construct a value of NonP2P DiffusionTracers data type.
-- ouroboros-consensus needs access to this constructor so we export this
-- function in order to avoid exporting the P2P and NonP2P internal modules.
--
mkDiffusionTracersNonP2P
  :: Tracer IO (WithMuxBearer (ConnectionId SockAddr) MuxTrace)
  -> Tracer IO NTN.HandshakeTr
  -> Tracer IO (WithMuxBearer (ConnectionId LocalAddress) MuxTrace)
  -> Tracer IO NTC.HandshakeTr
  -> Tracer IO DiffusionInitializationTracer
  -> Tracer IO TraceLedgerPeers
  -> Tracer IO (NTN.WithIPList (NTC.SubscriptionTrace SockAddr))
  -> Tracer IO (NTN.WithDomainName (NTC.SubscriptionTrace SockAddr))
  -> Tracer IO (NTN.WithDomainName NTN.DnsTrace)
  -> Tracer IO (NTC.WithAddr SockAddr NTC.ErrorPolicyTrace)
  -> Tracer IO (NTC.WithAddr LocalAddress NTC.ErrorPolicyTrace)
  -> Tracer IO NTN.AcceptConnectionsPolicyTrace
  -> DiffusionTracers
mkDiffusionTracersNonP2P
  a1 a2 a3 a4 a5 a6 a7 a8 a9
  a10 a11 a12 =
    DiffusionTracers
     (Common.DiffusionTracers
     a1 a2 a3 a4 a5 a6
     (Left $ NonP2P.DiffusionTracers
        a7 a8 a9 a10 a11 a12))

-- | Construct a value of P2P DiffusionTracers data type.
-- ouroboros-consensus needs access to this constructor so we export this
-- function in order to avoid exporting the P2P and NonP2P internal modules.
--
mkDiffusionTracersP2P
  :: Tracer IO (WithMuxBearer (ConnectionId SockAddr) MuxTrace)
  -> Tracer IO NTN.HandshakeTr
  -> Tracer IO (WithMuxBearer (ConnectionId LocalAddress) MuxTrace)
  -> Tracer IO NTC.HandshakeTr
  -> Tracer IO DiffusionInitializationTracer
  -> Tracer IO TraceLedgerPeers
  -> Tracer IO (P2P.TraceLocalRootPeers IOException)
  -> Tracer IO P2P.TracePublicRootPeers
  -> Tracer IO (P2P.TracePeerSelection SockAddr)
  -> Tracer
       IO
       (P2P.DebugPeerSelection
          SockAddr (P2P.NodeToNodePeerConnectionHandle 'InitiatorMode Void))
  -> Tracer
       IO
       (P2P.DebugPeerSelection
          SockAddr
          (P2P.NodeToNodePeerConnectionHandle 'InitiatorResponderMode ()))
  -> Tracer IO P2P.PeerSelectionCounters
  -> Tracer IO (P2P.PeerSelectionActionsTrace SockAddr)
  -> Tracer
       IO
       (P2P.ConnectionManagerTrace
          SockAddr
          (P2P.ConnectionHandlerTrace
             NodeToNodeVersion NodeToNodeVersionData))
  -> Tracer IO (P2P.ServerTrace SockAddr)
  -> Tracer IO (P2P.InboundGovernorTrace SockAddr)
  -> Tracer
       IO
       (P2P.ConnectionManagerTrace
          LocalAddress
          (P2P.ConnectionHandlerTrace
             NodeToClientVersion NodeToClientVersionData))
  -> Tracer IO (P2P.ServerTrace LocalAddress)
  -> Tracer IO (P2P.InboundGovernorTrace LocalAddress)
  -> DiffusionTracers
mkDiffusionTracersP2P
  a1 a2 a3 a4 a5 a6 a7 a8 a9
  a10 a11 a12 a13 a14 a15 a16
  a17 a18 a19 =
    DiffusionTracers
      (Common.DiffusionTracers
        a1 a2 a3 a4 a5 a6
        (Right $ P2P.DiffusionTracers
          a7 a8 a9 a10 a11 a12
          a13 a14 a15 a16 a17
          a18 a19))

-- | Field accessor for either P2P or NonP2P DiffusionArguments
-- DiffusionMode value
--
daDiffusionMode :: DiffusionArguments m -> DiffusionMode
daDiffusionMode (DiffusionArguments dargs) = either NonP2P.daDiffusionMode P2P.daDiffusionMode dargs

-- | runDataDiffusion for either P2P or Non-P2P node
--
runDataDiffusion
    :: DiffusionTracers
    -> DiffusionArguments IO
    -> DiffusionApplications
         RemoteAddress LocalAddress
         NodeToNodeVersionData NodeToClientVersionData
         IO
    -> IO (Either () Void)
runDataDiffusion (DiffusionTracers tr@Common.DiffusionTracers { Common.dtP2P })
                 (DiffusionArguments diffusionArguments)
                 (DiffusionApplications diffusionApplications) =
  case (dtP2P, diffusionArguments, diffusionApplications) of
    (Left t, Left da, Left dapp)    ->
      Left <$> NonP2P.runDataDiffusion (tr { Common.dtP2P = t}) da dapp
    (Right t, Right da, Right dapp) ->
      Right <$> P2P.runDataDiffusion (tr { Common.dtP2P = t}) da dapp
    _                               ->
      error "Non-matching arguments, every argument should be on the same side!"
