{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Interface to the ledger layer
module Ouroboros.Consensus.Ledger.Abstract (
    -- * Type-level validation marker
    Validated
    -- * Apply block
  , ApplyBlock (..)
  , UpdateLedger
    -- * Derived
  , applyLedgerBlock
  , reapplyLedgerBlock
  , refoldLedger
  , tickThenApply
  , tickThenApplyLedgerResult
  , tickThenReapply
  , tickThenReapplyLedgerResult
    -- ** Short-hand
  , ledgerTipHash
  , ledgerTipPoint
  , ledgerTipSlot
    -- * Re-exports
  , module Ouroboros.Consensus.Ledger.Basics
  , CoercibleLedgerState(..)
  ) where

import           Control.Monad.Except
import           Data.Kind (Type)
import           Data.Proxy
import           GHC.Stack (HasCallStack)

import           Ouroboros.Consensus.Block.Abstract
import           Ouroboros.Consensus.Ledger.Basics hiding (Output)
import qualified Ouroboros.Consensus.Ledger.Basics as Basics
import           Ouroboros.Consensus.Ticked
import           Ouroboros.Consensus.Util (repeatedly, (..:))
import Data.Coerce

-- | " Validated " transaction or block
--
-- The ledger defines how to validate transactions and blocks. It's possible the
-- type before and after validation may be distinct (eg Alonzo transactions),
-- which originally motivated this family.
--
-- We also gain the related benefit that certain interface functions, such as
-- those that /reapply/ blocks, can have a more precise type now. TODO
--
-- Similarly, the Node-to-Client mini protocols can explicitly indicate that the
-- client trusts the blocks from the local server, by having the server send
-- 'Validated' blocks to the client. TODO
--
-- Note that validation has different implications for a transaction than for a
-- block. In particular, a validated transaction can be " reapplied " to
-- different ledger states, whereas a validated block must only be " reapplied "
-- to the exact same ledger state (eg as part of rebuilding from an on-disk
-- ledger snapshot).
--
-- Since the ledger defines validation, see the ledger details for concrete
-- examples of what determines the validity (wrt to a 'LedgerState') of a
-- transaction and/or block. Example properties include: a transaction's claimed
-- inputs exist and are still unspent, a block carries a sufficient
-- cryptographic signature, etc.
data family Validated x :: Type

{-------------------------------------------------------------------------------
  Apply block to ledger state
-------------------------------------------------------------------------------}

class ( IsLedger l
      , HeaderHash l ~ HeaderHash blk
      , HasHeader blk
      , HasHeader (Header blk)
      ) => ApplyBlock (l :: LedgerStateKind) blk where

  type family Output l :: MapKind

  -- | Apply a block to the ledger state.
  --
  -- This is passed the ledger state ticked with the slot of the given block, so
  -- 'applyChainTickLedgerResult' has already been called.
  applyBlockLedgerResult ::
       HasCallStack
    => LedgerCfg l
    -> blk
    -> Ticked1 l ValuesMK -- Ticked1 l ValuesMK in New and Ticked1 l ValuesMK in Old
    -> Except (LedgerErr l) (LedgerResult l (l (Output l)))

  -- | Re-apply a block to the very same ledger state it was applied in before.
  --
  -- Since a block can only be applied to a single, specific, ledger state,
  -- if we apply a previously applied block again it will be applied in the
  -- very same ledger state, and therefore can't possibly fail.
  --
  -- It is worth noting that since we already know that the block is valid in
  -- the provided ledger state, the ledger layer should not perform /any/
  -- validation checks.
  reapplyBlockLedgerResult ::
       HasCallStack
    => LedgerCfg l
    -> blk
    -> Ticked1 l ValuesMK
    -> LedgerResult l (l (Output l))

class CoercibleLedgerState l where
  fromTickedOutput :: Ticked1 l (Basics.Output l) -> Ticked1 l ValuesMK
  fromOutput2      ::         l (Output l)        ->         l ValuesMK
  combineOutputs   :: Ticked1 l (Basics.Output l) -> l (Output l) -> l (Output l)

-- | Interaction with the ledger layer
class (ApplyBlock (LedgerState i blk) blk, TickedTableStuff (LedgerState i blk)) => UpdateLedger i blk

{-------------------------------------------------------------------------------
  Derived functionality
-------------------------------------------------------------------------------}

-- | 'lrResult' after 'applyBlockLedgerResult'
applyLedgerBlock ::
     (ApplyBlock l blk, HasCallStack)
  => LedgerCfg l
  -> blk
  -> Ticked1 l ValuesMK
  -> Except (LedgerErr l) (l (Output l))
applyLedgerBlock = fmap lrResult ..: applyBlockLedgerResult

-- | 'lrResult' after 'reapplyBlockLedgerResult'
reapplyLedgerBlock ::
     (ApplyBlock l blk, HasCallStack)
  => LedgerCfg l
  -> blk
  -> Ticked1 l ValuesMK
  -> l (Output l)
reapplyLedgerBlock = lrResult ..: reapplyBlockLedgerResult

tickThenApplyLedgerResult ::
     (ApplyBlock l blk, CoercibleLedgerState l)
  => LedgerCfg l
  -> blk
  -> l ValuesMK
  -> Except (LedgerErr l) (LedgerResult l (l (Output l)))
tickThenApplyLedgerResult cfg blk l = do
  let lrTick = applyChainTickLedgerResult cfg (blockSlot blk) l
  lrBlock <-   applyBlockLedgerResult cfg  blk  (fromTickedOutput (lrResult lrTick))
  pure LedgerResult {
      lrEvents = lrEvents lrTick <> lrEvents lrBlock
    , lrResult = combineOutputs (lrResult lrTick) (lrResult lrBlock)
    }

tickThenReapplyLedgerResult ::
     (ApplyBlock l blk, CoercibleLedgerState l)
  => LedgerCfg l
  -> blk
  -> l ValuesMK
  -> LedgerResult l (l (Output l))
tickThenReapplyLedgerResult cfg blk l =
  let lrTick  = applyChainTickLedgerResult cfg (blockSlot blk) l
      lrBlock = reapplyBlockLedgerResult   cfg            blk (fromTickedOutput (lrResult lrTick))
  in LedgerResult {
      lrEvents = lrEvents lrTick <> lrEvents lrBlock
    , lrResult = combineOutputs (lrResult lrTick) (lrResult lrBlock)
    }

tickThenApply ::
     (ApplyBlock l blk, CoercibleLedgerState l)
  => LedgerCfg l
  -> blk
  -> l ValuesMK
  -> Except (LedgerErr l) (l (Output l))
tickThenApply = fmap lrResult ..: tickThenApplyLedgerResult

tickThenReapply ::
     (ApplyBlock l blk, CoercibleLedgerState l)
  => LedgerCfg l
  -> blk
  -> l ValuesMK
  -> l (Output l)
tickThenReapply = lrResult ..: tickThenReapplyLedgerResult

refoldLedger ::
     forall l blk . (ApplyBlock l blk, CoercibleLedgerState l)
  => LedgerCfg l -> [blk] -> l ValuesMK -> l ValuesMK
refoldLedger cfg = repeatedly (\blk -> fromOutput2 @l . tickThenReapply cfg blk)

{-------------------------------------------------------------------------------
  Short-hand
-------------------------------------------------------------------------------}

-- | Wrapper around 'ledgerTipPoint' that uses a proxy to fix @blk@
--
-- This is occassionally useful to guide type inference
ledgerTipPoint ::
     (UpdateLedger i blk, Coercible (HeaderHash (LedgerState i blk mk)) (HeaderHash blk))
  => Proxy blk -> LedgerState i blk mk -> Point blk
ledgerTipPoint _ = castPoint . getTip

ledgerTipHash ::
     forall i blk mk. (UpdateLedger i blk, Coercible (HeaderHash (LedgerState i blk mk)) (HeaderHash blk))
  => LedgerState i blk mk -> ChainHash blk
ledgerTipHash = pointHash . (ledgerTipPoint (Proxy @blk))

ledgerTipSlot ::
     forall i blk mk. (UpdateLedger i blk, Coercible (HeaderHash (LedgerState i blk mk)) (HeaderHash blk))
  => LedgerState i blk mk -> WithOrigin SlotNo
ledgerTipSlot = pointSlot . (ledgerTipPoint (Proxy @blk))
