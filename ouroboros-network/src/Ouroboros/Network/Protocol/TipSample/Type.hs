{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE EmptyCase                #-}
{-# LANGUAGE PolyKinds                #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE StandaloneDeriving       #-}
{-# LANGUAGE StandaloneKindSignatures #-}

module Ouroboros.Network.Protocol.TipSample.Type where

import Data.Singletons

import Network.TypedProtocol.Core
import Network.TypedProtocol.Pipelined (N (..), Nat)
import Cardano.Slotting.Slot (SlotNo)

import Ouroboros.Network.Util.ShowProxy


-- | There are three of blocking requests: awiat until slot, await until
-- a tip will change; the third one has a dedicated type:
-- @'StFollowTip' :: 'TipSample' tip@.
--
data TipRequestKind where
    BlockUntilSlot    :: TipRequestKind
    BlockUntilTip     :: TipRequestKind


type SingTipRequest :: TipRequestKind -> Type
data SingTipRequest tipRequestKind where
    SingBlockUntilSlot :: SingBlockUntilSlot
    SingBlockUntilTip  :: SingBlockUntilTip

deriving instance Show (SingTipRequest tipRequestKind)

type instance Sing = SingTipRequest
instance SingI BlockUntilSlot where sing = SingBlockUntilSlot
instance SingI BlockUntilTip  where sing = SingBlockUntilTip


-- | `tip-sample` protocol, desigined for established peers to sample tip from
-- upstream peers.
--
data TipSample tip where
    StIdle      :: TipSample tip
    StFollowTip :: N -> TipSample tip
    StDone      :: TipSample tip

instance ShowProxy tip => ShowProxy (TipSample tip) where
    showProxy _ = "TipSample (" ++ showProxy (Proxy :: Proxy tip) ++ ")"

instance Protocol (TipSample tip) where
    data Message (TipSample tip) from to where

      -- | Request a series of tip changes starting at a given `SlotNo` (or
      -- after). The server is not obliged to send consecutive updates, what
      -- only matters is that the new tip is send as soon it becomes the
      -- server's tip.
      --
      MsgFollowTip :: Nat (S n)
                   -> SlotNo
                   -> Message (TipSample tip)
                              StIdle
                              (StFollowTip (S n))

      -- | Send a tip back to the client, hold on the agency.
      --
      MsgNextTip :: tip
                 -> Message (TipSample tip)
                            (StFollowTip (S (S n)))
                            (StFollowTip (S n))

      -- | Send last tip and pass the agency to the client.
      --
      MsgNextTipDone :: tip
                     -> Message (TipSample tip)
                                (StFollowTip (S Z))
                                StIdle

      -- | Terminating message (client side).
      --
      MsgDone :: Message (TipSample tip)
                         StIdle
                         StDone

    type StateAgency StIdle      = ClientAgency
    type StateAgency StFollowTip = ServerAgency
    type StateAgency StDone      = NobodyAgency


--
-- Show instances
--

deriving instance Show tip => Show (Message (TipSample tip) from to)
