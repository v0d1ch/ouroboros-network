{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE GADTs               #-}

-- | This is the starting point for a module that will bring together the
-- overall node to node protocol, as a collection of mini-protocols.
--
module Ouroboros.Network.NodeToNode (
    nodeToNodeProtocols
  , NodeToNodeProtocols (..)
  , MiniProtocolParameters (..)
  , defaultMiniProtocolParameters
  , NodeToNodeVersion (..)
  , NodeToNodeVersionData (..)
  , DictVersion (..)

  , NetworkConnectTracers (..)
  , nullNetworkConnectTracers

  , NetworkServerTracers (..)
  , nullNetworkServerTracers

  , connectTo

  , AcceptedConnectionsLimit (..)
  , withConnections

  -- * Subscription Workers
  -- ** IP subscriptin worker
  , IPSubscriptionTarget (..)
  , NetworkIPSubscriptionTracers
  , NetworkSubscriptionTracers (..)
  , nullNetworkSubscriptionTracers
  , SubscriptionParams (..)
  , IPSubscriptionParams

  -- ** DNS subscription worker
  , DnsSubscriptionTarget (..)
  , DnsSubscriptionParams
  , NetworkDNSSubscriptionTracers (..)
  , nullNetworkDNSSubscriptionTracers

    -- ** Versions
  , Versions (..)
  , simpleSingletonVersions
  , foldMapVersions
  , combineVersions
    -- *** Codecs
  , nodeToNodeHandshakeCodec
  , nodeToNodeVersionCodec
  , nodeToNodeCodecCBORTerm

  -- * Re-exports
  , ConnectionId
  , ConnectionId' (..)
  , MaybeAddress (..)
  , RemoteConnectionId
  , ProtocolLimitFailure
  , Handshake
  , LocalAddresses (..)

  -- ** Error Policies and Peer state
  , ErrorPolicies (..)
  , remoteNetworkErrorPolicy
  , localNetworkErrorPolicy
  , nullErrorPolicies
  , ErrorPolicy (..)
  , SuspendDecision (..)

  -- ** Traces
  , AcceptConnectionsPolicyTrace (..)
  , TraceSendRecv (..)
  , SubscriptionTrace (..)
  , DnsTrace (..)
  , ErrorPolicyTrace (..)
  , ConnectionTrace (..)
  , WithDomainName (..)
  , WithConnectionId
  , WithConnectionId' (..)
  , WithAddress (..)
  , HandshakeTr
  ) where

import           Control.Exception (IOException)
import           Control.Monad.Class.MonadST
import           Control.Monad.Class.MonadThrow

import qualified Data.ByteString.Lazy as BL
import           Data.Int (Int64)
import           Data.Time.Clock (DiffTime)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.Word

import           Network.Mux (WithMuxBearer (..))
import qualified Network.Socket as Socket

import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Term as CBOR

import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.Connections.Trace
import           Ouroboros.Network.Connections.Types (Connections)
import qualified Ouroboros.Network.Connections.Concurrent as Connection
import           Ouroboros.Network.Codec
import           Ouroboros.Network.CodecCBORTerm
import           Ouroboros.Network.Driver (TraceSendRecv(..))
import           Ouroboros.Network.Driver.Limits (ProtocolLimitFailure)
import           Ouroboros.Network.IOManager
import           Ouroboros.Network.Mux
import           Ouroboros.Network.Magic
import           Ouroboros.Network.ErrorPolicy
import           Ouroboros.Network.Protocol.Handshake.Type
import           Ouroboros.Network.Protocol.Handshake.Codec
import           Ouroboros.Network.Protocol.Handshake.Version hiding (Accept)
import qualified Ouroboros.Network.Protocol.Handshake.Version as V
import           Ouroboros.Network.BlockFetch.Client (BlockFetchProtocolFailure)
import           Ouroboros.Network.Snocket
import           Ouroboros.Network.Socket hiding (withConnections)
import qualified Ouroboros.Network.Socket as Socket (withConnections)
import           Ouroboros.Network.Subscription.Ip (IPSubscriptionParams, SubscriptionParams (..))
import           Ouroboros.Network.Subscription.Ip ( IPSubscriptionTarget (..)
                                                   , LocalAddresses (..)
                                                   , SubscriptionTrace (..)
                                                   )
import           Ouroboros.Network.Subscription.Dns (DnsSubscriptionParams)
import           Ouroboros.Network.Subscription.Dns ( DnsSubscriptionTarget (..)
                                                    , DnsTrace (..)
                                                    , WithDomainName (..)
                                                    )
import qualified Ouroboros.Network.TxSubmission.Inbound as TxInbound
import qualified Ouroboros.Network.TxSubmission.Outbound as TxOutbound
import           Ouroboros.Network.Tracers


-- The Handshake tracer types are simply terrible.
type HandshakeTr = WithMuxBearer
                    (ConnectionId Socket.SockAddr)
                    (TraceSendRecv (Handshake NodeToNodeVersion CBOR.Term))


data NodeToNodeProtocols appType bytes m a b = NodeToNodeProtocols {
    -- | chain-sync mini-protocol
    --
    chainSyncProtocol    :: RunMiniProtocol appType bytes m a b,

    -- | block-fetch mini-protocol
    --
    blockFetchProtocol   :: RunMiniProtocol appType bytes m a b,

    -- | tx-submission mini-protocol
    --
    txSubmissionProtocol :: RunMiniProtocol appType bytes m a b
  }


data MiniProtocolParameters = MiniProtocolParameters {
    chainSyncPipeliningHighMark :: !Word32,
    -- ^ high threshold for pipelining (we will never exceed that many
    -- messages pipelined).

      chainSyncPipeliningLowMark  :: !Word32,
    -- ^ low threshold: if we hit the 'chainSyncPipeliningHighMark' we will
    -- listen for responses until there are at most
    -- 'chainSyncPipeliningLowMark' pipelined message
    --
    -- Must be smaller than 'chainSyncPipeliningHighMark'.
    --
    -- Note: 'chainSyncPipeliningLowMark' and 'chainSyncPipeliningLowMark'
    -- are passed to 'pipelineDecisionLowHighMark'.

      blockFetchPipeliningMax     :: !Word,
    -- ^ maximal number of pipelined messages in 'block-fetch' mini-protocol.

      txSubmissionMaxUnacked       :: !Word16
    -- ^ maximal number of unacked tx (pipelining is bounded by twice this
    -- number)
    }

defaultMiniProtocolParameters :: MiniProtocolParameters
defaultMiniProtocolParameters = MiniProtocolParameters {
    chainSyncPipeliningLowMark  = 200
  , chainSyncPipeliningHighMark = 300
  , blockFetchPipeliningMax     = 100
  , txSubmissionMaxUnacked       = 10
  }

-- | Make an 'OuroborosApplication' for the bundle of mini-protocols that
-- make up the overall node-to-node protocol.
--
-- This function specifies the wire format protocol numbers.
--
-- The application specific protocol numbers start from 2.  The
-- @'MiniProtocolNum' 0@ is reserved for the 'Handshake' protocol, while
-- @'MiniProtocolNum' 1@ is reserved for DeltaQ messages.
-- 'Handshake' protocol is not included in 'NodeToNodeProtocols' as it runs
-- before mux is started but it reusing 'MuxBearer' to send and receive
-- messages.  Only when the handshake protocol suceedes, we will know which
-- protocols to run / multiplex.
--
-- These are chosen to not overlap with the node to client protocol numbers (and
-- the handshake protocol number).  This is not essential for correctness, but
-- is helpful to allow a single shared implementation of tools that can analyse
-- both protocols, e.g.  wireshark plugins.
--
nodeToNodeProtocols
  :: MiniProtocolParameters
  -> NodeToNodeProtocols appType bytes m a b
  -> OuroborosApplication appType bytes m a b
nodeToNodeProtocols MiniProtocolParameters {
                        chainSyncPipeliningHighMark,
                        blockFetchPipeliningMax,
                        txSubmissionMaxUnacked
                      }
                    NodeToNodeProtocols {
                        chainSyncProtocol,
                        blockFetchProtocol,
                        txSubmissionProtocol
                      } =
    OuroborosApplication [
      MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 2,
        miniProtocolLimits = chainSyncProtocolLimits,
        miniProtocolRun    = chainSyncProtocol
      }
    , MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 3,
        miniProtocolLimits = blockFetchProtocolLimits,
        miniProtocolRun    = blockFetchProtocol
      }
    , MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 4,
        miniProtocolLimits = txSubmissionProtocolLimits,
        miniProtocolRun    = txSubmissionProtocol
      }
    ]
  where
    addSafetyMargin :: Int64 -> Int64
    addSafetyMargin x = x + x `div` 10

    chainSyncProtocolLimits
      , blockFetchProtocolLimits
      , txSubmissionProtocolLimits :: MiniProtocolLimits

    chainSyncProtocolLimits =
      MiniProtocolLimits {
          -- chain sync has two potentially large messages:
          --
          -- - 'MsgFindIntersect'
          --      it can include up to 18 'Points' (see
          --      'Ouroboros.Consensus.ChainSyncClient.chainSyncClient'; search
          --      for the 'offset' term)
          -- - 'MnsgRollForward'
          --      These messages are pipelined.  Up to 300 messages can be
          --      pipelined (this is defined in
          --      'Ouroboros.Consensus.NodeKernel.NodeArgs', which is
          --      instantiated in 'Ouroboros.Consensus.Node.mkNodeArgs').
          --
          -- Sizes:
          -- - @Point (HeaderHash ByronBlock)@ - 45 as witnessed by
          --    @encodedPointSize (szGreedy :: Proxy (HeaderHash ByronBlock) -> Size) (Proxy :: Proxy (Point ByronBlock))
          --    or
          --    ```
          --      1  -- encodeListLen 2
          --    + 1  -- encode tag
          --    + 9  -- encode 'SlotNo', i.e. a 'Word64'
          --    + 34 -- encode @HeaderHas ByronBlock@ which resolves to
          --            'ByronHash' which is a newtype wrapper around
          --             'Cardano.Chain.Block.HeaderHash'
          --    = 45
          --
          -- - @Tip (HeaderHash ByronBlock)@ - 55 as witnessed by
          --    @encodedTipSize (szGreedy :: Proxy (HeaderHash ByronBlock) -> Size) (Proxy :: Proxy (Tip ByronBlock))
          --    or
          --    ```
          --      1  -- encodeListLen 2
          --    + 45 -- point size
          --    + 9  -- 'BlockNo', e.g. 'Word64'
          --    + 55
          --    ```
          --
          -- - @MsgFindIntersect@ carrying 18 @Point (HeaderHash ByronBlock)@
          --   ```
          --     1 -- encodeListLen 2
          --   + 1 -- enocdeWord 4
          --   + 2 -- encodeListLenIndef + encodeBreak
          --   + (18 * 55)
          --   = 994
          --   ```
          --
          -- - @MsgRollForward@
          --   ```
          --     1   -- encodeListLen 3
          --   + 1   -- encodeWord 2
          --   + 659 -- as witnessed by 'ts_prop_sizeABlockOrBoundaryHdr' in 'cardano-ledger'
          --         -- 'Header ByronBlock' resolves to 'ByronHeader' which
          --         -- binary format is the same as
          --         -- 'Cardano.Chain.Block.ABlockOrBoundaryHdr'
          --   + 55  -- @Tip ByronBlock@
          --   = 716
          --   ```
          --
          -- Since chain sync can pipeline up to 'chainSyncPipeliningHighMark' of 'MsgRollForward'
          -- messages the maximal queue size can be
          -- @chainSyncPipeliningHighMark * 716@.  The current value of
          -- 'chainSyncPipeliningHighMark' is '300' thus the upper bound is
          -- `214.8Kb`)  We add 10% to that for safety.
          --
          maximumIngressQueue = addSafetyMargin $
        fromIntegral chainSyncPipeliningHighMark * 716
      }

    blockFetchProtocolLimits = MiniProtocolLimits {
        -- block-fetch client can pipeline at most 'blockFetchPipeliningMax'
        -- blocks (currently '10').  This is currently hard coded in
        -- 'Ouroboros.Network.BlockFetch.blockFetchLogic' (where
        -- @maxInFlightReqsPerPeer = 10@ is specified).  In the future the
        -- block fetch client will count bytes rather than blocks.  By far
        -- the largest (and the only pipelined message) in 'block-fetch'
        -- protocol is 'MsgBlock'.  We put a hard limit of 2Mb on each block.
        --
        -- - size of 'MsgBlock'
        --   ```
        --       1               -- encodeListLen 2
        --     + 1               -- encodeWord 4
        --     + 2 * 1024 * 1024 -- block size limit
        --     = 2_097_154
        --   ```
        --
        -- So the overall limit is `10 * 2_097_154 = 20_971_540` (i.e. aroudn
        -- '20Mb'), we add 10% safety margin:
        --
        maximumIngressQueue = addSafetyMargin $
      fromIntegral blockFetchPipeliningMax * 2_097_154
    }

    txSubmissionProtocolLimits = MiniProtocolLimits {
        -- tx-submission server can pipeline both 'MsgRequestTxIds' and
        -- 'MsgRequestTx'. This means that there can be many
        -- 'MsgReplyTxIds', 'MsgReplyTxs' messages in an inbound queue (their
        -- sizes are strictly greater than the corresponding request
        -- messages).
        --
        -- Each 'MsgRequestTx' can contain at max @maxTxIdsToRequest = 3@
        -- (defined in -- 'Ouroboros.Network.TxSubmission.Inbound.txSubmissionInbound')
        --
        -- Each 'MsgRequestTx' can request at max @maxTxToRequest = 2@
        -- (defined in -- 'Ouroboros.Network.TxSubmission.Inbound.txSubmissionInbound')
        --
        -- The 'txSubmissionInBound' server can at most put `100`
        -- unacknowledged transactions.  It also pipelines both 'MsgRequestTx`
        -- and `MsgRequestTx` in turn. This means that the inbound queue can
        -- have at most `100` `MsgRequestTxIds` and `MsgRequestTx` which will
        -- contain a single `TxId` / `Tx`.
        --
        -- TODO: the unacknowledged transactions are configured in `NodeArgs`,
        -- and we should take this parameter as an input for this computation.
        --
        -- The upper bound of size of a single transaction is 64k, while the
        -- size of `TxId` is `34` bytes (`type TxId = Hash Tx`).
        --
        -- Ingress side of `txSubmissinInbound`
        --
        -- - 'MsgReplyTxs' carrying a single `TxId`:
        -- ```
        --    1  -- encodeListLen 2
        --  + 1  -- encodeWord 1
        --  + 1  -- encodeListLenIndef
        --  + 1  -- encodeListLen 2
        --  + 34 -- encode 'TxId'
        --  + 5  -- encodeWord32 (size of tx)
        --  + 1  -- encodeBreak
        --  = 44
        -- ```
        -- - 'MsgReplyTx' carrying a single 'Tx':
        -- ```
        --    1      -- encodeListLen 2
        --  + 1      -- encodeWord 3
        --  + 1      -- encodeListLenIndef
        --  + 65_536 -- 64kb transaction
        --  + 1      -- encodeBreak
        --  = 65_540
        -- ```
        --
        -- On the ingress side of 'txSubmissionOutbound' we can have at most
        -- `MaxUnacked' 'MsgRequestTxsIds' and the same ammount of
        -- 'MsgRequsetTx' containing a single 'TxId'.  The size of
        -- 'MsgRequestTxsIds' is much smaller that 'MsgReplyTx', and the size
        -- of `MsgReqeustTx` with a single 'TxId' is smaller than
        -- 'MsgReplyTxIds' which contains a single 'TxId' (it just contains
        -- the 'TxId' without the size of 'Tx' in bytes).  So the ingress
        -- queue of 'txSubmissionOutbound' is bounded by the ingress side of
        -- the 'txSubmissionInbound'
        --
        -- Currently the value of 'txSubmissionMaxUnacked' is '100', for
        -- which the upper bound is `100 * (44 + 65_540) = 6_558_400`, we add
        -- 10% as a safety margin.
        --
        maximumIngressQueue = addSafetyMargin $
      fromIntegral txSubmissionMaxUnacked * (44 + 65_540)
    }


-- | Enumeration of node to node protocol versions.
--
data NodeToNodeVersion = NodeToNodeV_1
  deriving (Eq, Ord, Enum, Bounded, Show, Typeable)

nodeToNodeVersionCodec :: CodecCBORTerm (Text, Maybe Int) NodeToNodeVersion
nodeToNodeVersionCodec = CodecCBORTerm { encodeTerm, decodeTerm }
  where
    encodeTerm NodeToNodeV_1  = CBOR.TInt 1

    decodeTerm (CBOR.TInt 1) = Right NodeToNodeV_1
    decodeTerm (CBOR.TInt n) = Left ( T.pack "decode NodeToNodeVersion: unknonw tag: "
                                        <> T.pack (show n)
                                    , Just n
                                    )
    decodeTerm _ = Left ( T.pack "decode NodeToNodeVersion: unexpected term"
                        , Nothing)

-- | 'Hanshake' codec for the @node-to-node@ protocol suite.
--
nodeToNodeHandshakeCodec :: ( MonadST    m
                            , MonadThrow m
                            )
                         => Codec (Handshake NodeToNodeVersion CBOR.Term)
                                  CBOR.DeserialiseFailure m BL.ByteString
nodeToNodeHandshakeCodec = codecHandshake nodeToNodeVersionCodec

-- | Version data for NodeToNode protocol v1
--
newtype NodeToNodeVersionData = NodeToNodeVersionData
  { networkMagic :: NetworkMagic }
  deriving (Eq, Show, Typeable)

instance Acceptable NodeToNodeVersionData where
    acceptableVersion local remote | local == remote = V.Accept
                                   | otherwise =  Refuse $ T.pack $ "version data mismatch: " ++ show local
                                   ++ " /= " ++ show remote

nodeToNodeCodecCBORTerm :: CodecCBORTerm Text NodeToNodeVersionData
nodeToNodeCodecCBORTerm = CodecCBORTerm {encodeTerm, decodeTerm}
  where
    encodeTerm :: NodeToNodeVersionData -> CBOR.Term
    encodeTerm NodeToNodeVersionData { networkMagic } =
      CBOR.TInt (fromIntegral $ unNetworkMagic networkMagic)

    decodeTerm :: CBOR.Term -> Either Text NodeToNodeVersionData
    decodeTerm (CBOR.TInt x) | x >= 0 && x <= 0xffffffff = Right (NodeToNodeVersionData $ NetworkMagic $ fromIntegral x)
                             | otherwise                 = Left $ T.pack $ "networkMagic out of bound: " <> show x
    decodeTerm t             = Left $ T.pack $ "unknown encoding: " ++ show t


-- | A specialised version of @'Ouroboros.Network.Socket.connectToNode'@.
--
connectTo
  :: Snocket IO Socket.Socket Socket.SockAddr
  -> NetworkConnectTracers Socket.SockAddr NodeToNodeVersion
  -> Versions NodeToNodeVersion
              DictVersion
              (ConnectionId Socket.SockAddr ->
                 OuroborosApplication InitiatorApp BL.ByteString IO a b)
  -> Maybe Socket.SockAddr
  -> Socket.SockAddr
  -> IO ()
connectTo sn =
    connectToNode sn nodeToNodeHandshakeCodec cborTermVersionDataCodec

-- | `Ouroboros.Network.Socket.withConnections` but with the protocol types
-- specialized. It also fills in the version data codec
-- `cborTermVersionDataCodec` and `acceptEq` to determine when to accept a
-- version.
withConnections
  :: forall request fd addr t.
     ( Ord addr )
  => ErrorPolicies
  -> Snocket IO fd addr
  -> (forall provenance . request provenance -> SomeVersionedApplication
       NodeToNodeVersion DictVersion addr provenance)
  -> (Connections (ConnectionId addr) fd request
       (Connection.Reject RejectConnection)
       (Connection.Accept (ConnectionHandle IO))
       IO -> IO t)
  -> IO t
withConnections errorPolicies sn mkApp =
    Socket.withConnections sn nodeToNodeHandshakeCodec mkConnectionData
  where
    -- Must give a type signature. Trying to do this in-line will confuse the
    -- type checker.
    mkConnectionData
      :: request provenance
      -> ConnectionData NodeToNodeVersion provenance addr
    mkConnectionData request = case mkApp request of
      SomeVersionedResponderApp serverTracers versions -> ConnectionDataRemote
        serverTracers
        errorPolicies
        cborTermVersionDataCodec
        (\(DictVersion _) -> acceptableVersion)
        versions
      SomeVersionedInitiatorApp connectTracers versions -> ConnectionDataLocal
        connectTracers
        errorPolicies
        cborTermVersionDataCodec
        versions

-- | A minimal error policy for remote peers, which only handles exceptions
-- raised by `ouroboros-network`.
--
remoteNetworkErrorPolicy :: ErrorPolicies
remoteNetworkErrorPolicy = ErrorPolicies {
      epAppErrorPolicies = [
          -- Handshake client protocol error: we either did not recognise received
          -- version or we refused it.  This is only for outbound connections,
          -- thus we suspend the consumer.
          ErrorPolicy
            $ \(_ :: HandshakeClientProtocolError NodeToNodeVersion)
                  -> Just misconfiguredPeer

          -- exception thrown by `runPeerWithLimits`
        , ErrorPolicy
            $ \(_ :: ProtocolLimitFailure)
                   -> Just theyBuggyOrEvil

          -- deserialisation failure; this means that the remote peer is either
          -- buggy, adversarial, or the connection return garbage.  In the last
          -- case it's also good to shutdown both the consumer and the
          -- producer, as it's likely that the other side of the connection
          -- will return grabage as well.
        , ErrorPolicy
            $ \(_ :: CBOR.DeserialiseFailure)
                  -> Just theyBuggyOrEvil

          -- the connection was unexpectedly closed, we suspend the peer for
          -- a 'shortDelay'
        , ErrorPolicy
            $ \(e :: MuxError)
                  -> case errorType e of
                        MuxUnknownMiniProtocol  -> Just theyBuggyOrEvil
                        MuxDecodeError          -> Just theyBuggyOrEvil
                        MuxIngressQueueOverRun  -> Just theyBuggyOrEvil
                        MuxInitiatorOnly        -> Just theyBuggyOrEvil

                        -- in case of bearer closed / or IOException we suspend
                        -- the peer for a short time
                        --
                        -- TODO: an exponential backoff would be nicer than a fixed 20s
                        -- TODO: right now we cannot suspend just the
                        -- 'responder'.  If a 'responder' throws 'MuxError' we
                        -- might not want to shutdown the consumer (which is
                        -- using different connection), as we do below:
                        MuxBearerClosed         -> Just (SuspendPeer shortDelay shortDelay)
                        MuxIOException{}        -> Just (SuspendPeer shortDelay shortDelay)
                        MuxSDUReadTimeout       -> Just (SuspendPeer shortDelay shortDelay)
                        MuxSDUWriteTimeout      -> Just (SuspendPeer shortDelay shortDelay)

          -- Error policy for TxSubmission protocol: outbound side (client role)
        , ErrorPolicy
            $ \(_ :: TxOutbound.TxSubmissionProtocolError)
                  -> Just theyBuggyOrEvil

          -- Error policy for TxSubmission protocol: inbound side (server role)
        , ErrorPolicy
            $ \(_ :: TxInbound.TxSubmissionProtocolError)
                  -> Just theyBuggyOrEvil

          -- Error policy for BlockFetch protocol: consumer side (client role)
        , ErrorPolicy
            $ \(_ :: BlockFetchProtocolFailure)
                  -> Just theyBuggyOrEvil

          -- Error thrown by 'IOManager', this is fatal on Windows, and it will
          -- never fire on other platofrms.
        , ErrorPolicy
            $ \(_ :: IOManagerError)
                  -> Just Throw
        ],

      -- Exception raised during connect; suspend connecting to that peer for
      -- a 'shortDelay'
      epConErrorPolicies = [
          ErrorPolicy $ \(_ :: IOException) -> Just $
            SuspendConsumer shortDelay

        , ErrorPolicy
            $ \(_ :: IOManagerError)
                  -> Just Throw
        ]
    }
  where
    theyBuggyOrEvil :: SuspendDecision DiffTime
    theyBuggyOrEvil = SuspendPeer defaultDelay defaultDelay

    misconfiguredPeer :: SuspendDecision DiffTime
    misconfiguredPeer = SuspendConsumer defaultDelay

    defaultDelay :: DiffTime
    defaultDelay = 200 -- seconds

    shortDelay :: DiffTime
    shortDelay = 20 -- seconds

-- | Error policy for local clients.  This is equivalent to
-- 'nullErrorPolicies', but explicit in the errors which can be catched.
--
-- We are very permissive here, and very strict in the
-- `NodeToClient.networkErrorPolicy`.  After any failure the client will be
-- killed and not penalised by this policy.  This allows to restart the local
-- client without a delay.
--
localNetworkErrorPolicy :: ErrorPolicies
localNetworkErrorPolicy = ErrorPolicies {
      epAppErrorPolicies = [
          -- exception thrown by `runPeerWithLimits`
          ErrorPolicy
            $ \(_ :: ProtocolLimitFailure)
                  -> Nothing

          -- deserialisation failure
        , ErrorPolicy
            $ \(_ :: CBOR.DeserialiseFailure) -> Nothing

          -- the connection was unexpectedly closed, we suspend the peer for
          -- a 'shortDelay'
        , ErrorPolicy
          $ \(_ :: MuxError) -> Nothing
        ],

      -- The node never connects to a local client
      epConErrorPolicies = []
    }

type RemoteConnectionId = ConnectionId Socket.SockAddr
