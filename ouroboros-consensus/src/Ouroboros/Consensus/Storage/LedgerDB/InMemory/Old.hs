{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DerivingStrategies #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuantifiedConstraints #-}
-- |

module Ouroboros.Consensus.Storage.LedgerDB.InMemory.Old where

import           Control.Monad.Except hiding (ap)
import           Data.Functor.Identity
import           Data.Word
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)
import           Data.Kind

import           Ouroboros.Network.AnchoredSeq (Anchorable (..),
                     AnchoredSeq (..))
import qualified Ouroboros.Network.AnchoredSeq as AS

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Util

import           Ouroboros.Consensus.Storage.LedgerDB.InMemory.Base

{-------------------------------------------------------------------------------
  Ledger DB types
-------------------------------------------------------------------------------}

type BaseLedgerState blk = LedgerState Old blk

type instance BaseLedgerStateMK (BaseLedgerState blk) = ValuesMK

type BaseLedgerState' blk = BaseLedgerState blk (BaseLedgerStateMK (BaseLedgerState blk)) -- LedgerState Old blk ValuesMK

-- | Internal state of the ledger DB
--
-- The ledger DB looks like
--
-- > anchor |> snapshots <| current
--
-- where @anchor@ records the oldest known snapshot and @current@ the most
-- recent. The anchor is the oldest point we can roll back to.
--
-- We take a snapshot after each block is applied and keep in memory a window
-- of the last @k@ snapshots. We have verified empirically (#1936) that the
-- overhead of keeping @k snapshots in memory is small, i.e., about 5%
-- compared to keeping a snapshot every 100 blocks. This is thanks to sharing
-- between consecutive snapshots.
--
-- As an example, suppose we have @k = 6@. The ledger DB grows as illustrated
-- below, where we indicate the anchor number of blocks, the stored snapshots,
-- and the current ledger.
--
-- > anchor |> #   [ snapshots ]                   <| tip
-- > ---------------------------------------------------------------------------
-- > G      |> (0) [ ]                             <| G
-- > G      |> (1) [ L1]                           <| L1
-- > G      |> (2) [ L1,  L2]                      <| L2
-- > G      |> (3) [ L1,  L2,  L3]                 <| L3
-- > G      |> (4) [ L1,  L2,  L3,  L4]            <| L4
-- > G      |> (5) [ L1,  L2,  L3,  L4,  L5]       <| L5
-- > G      |> (6) [ L1,  L2,  L3,  L4,  L5,  L6]  <| L6
-- > L1     |> (6) [ L2,  L3,  L4,  L5,  L6,  L7]  <| L7
-- > L2     |> (6) [ L3,  L4,  L5,  L6,  L7,  L8]  <| L8
-- > L3     |> (6) [ L4,  L5,  L6,  L7,  L8,  L9]  <| L9   (*)
-- > L4     |> (6) [ L5,  L6,  L7,  L8,  L9,  L10] <| L10
-- > L5     |> (6) [*L6,  L7,  L8,  L9,  L10, L11] <| L11
-- > L6     |> (6) [ L7,  L8,  L9,  L10, L11, L12] <| L12
-- > L7     |> (6) [ L8,  L9,  L10, L12, L12, L13] <| L13
-- > L8     |> (6) [ L9,  L10, L12, L12, L13, L14] <| L14
--
-- The ledger DB must guarantee that at all times we are able to roll back @k@
-- blocks. For example, if we are on line (*), and roll back 6 blocks, we get
--
-- > L3 |> []
data instance LedgerDB (BaseLedgerState blk) = LedgerDB {
  ledgerDbCheckpoints :: AnchoredSeq
                         (WithOrigin SlotNo)
                         (Checkpoint blk)
                         (Checkpoint blk)
  }
  deriving (Generic)

deriving instance Eq       (BaseLedgerState' blk) => Eq       (LedgerDB (BaseLedgerState blk))
deriving instance NoThunks (BaseLedgerState' blk) => NoThunks (LedgerDB (BaseLedgerState blk))

instance IsLedger (BaseLedgerState blk) => GetTip (LedgerDB (BaseLedgerState blk)) where
  getTip = castPoint . getTip . ledgerDbCurrent

-- | Internal newtype wrapper around a ledger state @l@ so that we can define a
-- non-blanket 'Anchorable' instance.
newtype Checkpoint blk = Checkpoint {
      unCheckpoint :: BaseLedgerState' blk
    }
  deriving (Generic)
deriving instance Eq                (BaseLedgerState' blk) => Eq       (Checkpoint blk)
deriving anyclass instance NoThunks (BaseLedgerState' blk) => NoThunks (Checkpoint blk)
instance ShowLedgerState (BaseLedgerState blk) => Show (Checkpoint blk) where
  showsPrec = error "showsPrec @CheckPoint"

instance GetTip (BaseLedgerState' blk)
         => Anchorable (WithOrigin SlotNo) (Checkpoint blk) (Checkpoint blk) where
  asAnchor = id
  getAnchorMeasure _ = getTipSlot . unCheckpoint

{-------------------------------------------------------------------------------
  LedgerDB proper
-------------------------------------------------------------------------------}

ledgerDbWithAnchor ::
     GetTip (BaseLedgerState' blk)
  => (BaseLedgerState blk) (BaseLedgerStateMK (BaseLedgerState blk))
  -> LedgerDB (BaseLedgerState blk)
ledgerDbWithAnchor anchor = LedgerDB {
      ledgerDbCheckpoints = Empty (Checkpoint anchor)
    }

{-------------------------------------------------------------------------------
  Block application
-------------------------------------------------------------------------------}

pureBlock :: blk -> Ap m (BaseLedgerState blk) blk ()
pureBlock = ReapplyVal

-- | 'Ap' is used to pass information about blocks to ledger DB updates
--
-- The constructors serve two purposes:
--
-- * Specify the various parameters
--   a. Are we passing the block by value or by reference?
--   b. Are we applying or reapplying the block?
--
-- * Compute the constraint @c@ on the monad @m@ in order to run the query:
--   a. If we are passing a block by reference, we must be able to resolve it.
--   b. If we are applying rather than reapplying, we might have ledger errors.
data Ap :: (Type -> Type) -> LedgerStateKind -> Type -> Constraint -> Type where
  ReapplyVal ::           blk -> Ap m (BaseLedgerState blk) blk ( )
  ApplyVal   ::           blk -> Ap m (BaseLedgerState blk) blk (                       ThrowsLedgerError m (BaseLedgerState blk) blk)
  ReapplyRef :: RealPoint blk -> Ap m (BaseLedgerState blk) blk (ResolvesBlocks m blk)
  ApplyRef   :: RealPoint blk -> Ap m (BaseLedgerState blk) blk (ResolvesBlocks m blk , ThrowsLedgerError m (BaseLedgerState blk) blk)

  -- | 'Weaken' increases the constraint on the monad @m@.
  --
  -- This is primarily useful when combining multiple 'Ap's in a single
  -- homogeneous structure.
  Weaken :: (c' => c) => Ap m (BaseLedgerState blk) blk c -> Ap m (BaseLedgerState blk) blk c'

{-------------------------------------------------------------------------------
  Internal utilities for 'Ap'
-------------------------------------------------------------------------------}

-- | Apply block to the current ledger state
--
-- We take in the entire 'LedgerDB' because we record that as part of errors.
applyBlock :: forall blk c m .
              ApplyBlockC m c (BaseLedgerState blk) blk
           => LedgerCfg (BaseLedgerState blk)
           -> Ap m (BaseLedgerState blk) blk c
           -> LedgerDB (BaseLedgerState blk)
           -> m (BaseLedgerState blk (Output (BaseLedgerState blk)))
applyBlock cfg ap db = case ap of
    ReapplyVal b ->
      return $
        tickThenReapply cfg b l
    ApplyVal b ->
      either (throwLedgerError db (blockRealPoint b)) return $ runExcept $
        tickThenApply cfg b l
    ReapplyRef r  -> do
      b <- resolveBlock r
      return $
        tickThenReapply cfg b l
    ApplyRef r -> do
      b <- resolveBlock r
      either (throwLedgerError db r) return $ runExcept $
        tickThenApply cfg b l
    Weaken ap' ->
      applyBlock cfg ap' db
  where
    l :: LedgerState Old blk ValuesMK
    l = ledgerDbCurrent db

{-------------------------------------------------------------------------------
  Queries
-------------------------------------------------------------------------------}

-- | The ledger state at the tip of the chain
--(BaseLedgerState blk) ValuesMK
ledgerDbCurrent ::
     GetTip (BaseLedgerState' blk)
  => LedgerDB (BaseLedgerState blk)
  -> BaseLedgerState' blk
ledgerDbCurrent = either unCheckpoint unCheckpoint . AS.head . ledgerDbCheckpoints


-- | Information about the state of the ledger at the anchor
ledgerDbAnchor ::
     LedgerDB (BaseLedgerState blk)
  -> BaseLedgerState' blk
ledgerDbAnchor = unCheckpoint . AS.anchor . ledgerDbCheckpoints

-- | All snapshots currently stored by the ledger DB (new to old)
--
-- This also includes the snapshot at the anchor. For each snapshot we also
-- return the distance from the tip.
ledgerDbSnapshots ::
     LedgerDB (BaseLedgerState blk)
  -> [(Word64, BaseLedgerState' blk)]
ledgerDbSnapshots db =
    zip
      [0..]
      (map unCheckpoint (AS.toNewestFirst $ ledgerDbCheckpoints db)
        <> [unCheckpoint (AS.anchor $ ledgerDbCheckpoints db)])


-- | How many blocks can we currently roll back?
ledgerDbMaxRollback ::
     GetTip (BaseLedgerState' blk)
  => LedgerDB (BaseLedgerState blk)
  -> Word64
ledgerDbMaxRollback db = fromIntegral (AS.length $ ledgerDbCheckpoints db)


-- | Reference to the block at the tip of the chain
ledgerDbTip ::
     IsLedger (BaseLedgerState blk)
  => LedgerDB (BaseLedgerState blk)
  -> Point (BaseLedgerState blk)
ledgerDbTip = castPoint . getTip . ledgerDbCurrent

-- | Have we seen at least @k@ blocks?
ledgerDbIsSaturated ::
     GetTip (BaseLedgerState' blk)
  => SecurityParam
  -> LedgerDB (BaseLedgerState blk)
  -> Bool
ledgerDbIsSaturated (SecurityParam k) db =
    ledgerDbMaxRollback db >= k

-- | Get a past ledger state
--
--  \( O(\log(\min(i,n-i)) \)
--
-- When no ledger state (or anchor) has the given 'Point', 'Nothing' is
-- returned.
ledgerDbPast ::
     ( HasHeader blk
     , IsLedger (BaseLedgerState blk)
     )
  => Point blk
  -> LedgerDB (BaseLedgerState blk)
  -> Maybe (BaseLedgerState' blk)
ledgerDbPast pt db = ledgerDbCurrent <$> ledgerDbPrefix pt db

ledgerDbPrefix ::
     ( HasHeader blk
     , IsLedger (BaseLedgerState blk)
     )
  => Point blk
  ->        LedgerDB (BaseLedgerState blk)
  -> Maybe (LedgerDB (BaseLedgerState blk))
ledgerDbPrefix pt db
    | pt == castPoint (getTip (ledgerDbAnchor db))
    = Just $ ledgerDbWithAnchor $ ledgerDbAnchor db
    | otherwise
    =  do
        checkpoints' <- AS.rollback
                          (pointSlot pt)
                          ((== pt) . castPoint . getTip . unCheckpoint . either id id)
                          (ledgerDbCheckpoints db)

        return $ LedgerDB checkpoints'

-- | Prune snapshots until at we have at most @k@ snapshots in the LedgerDB,
-- excluding the snapshots stored at the anchor.
ledgerDbPrune ::
     GetTip (BaseLedgerState' blk)
  => SecurityParam
  -> LedgerDB (BaseLedgerState blk)
  -> LedgerDB (BaseLedgerState blk)
ledgerDbPrune (SecurityParam k) db = db {
      ledgerDbCheckpoints = AS.anchorNewest k (ledgerDbCheckpoints db)
    }

{-------------------------------------------------------------------------------
  Internal updates
-------------------------------------------------------------------------------}

-- | Push an updated ledger state
pushLedgerState ::
     (GetTip (BaseLedgerState' blk))
  => SecurityParam
  -> BaseLedgerState' blk  -- ^ Updated ledger state
  -> LedgerDB (BaseLedgerState blk)
  -> LedgerDB (BaseLedgerState blk)
pushLedgerState secParam current' db@LedgerDB{..} =
    ledgerDbPrune secParam $ db {
        ledgerDbCheckpoints = ledgerDbCheckpoints AS.:> Checkpoint current'
    }

{-------------------------------------------------------------------------------
  Internal: rolling back
-------------------------------------------------------------------------------}

-- | Rollback
--
-- Returns 'Nothing' if maximum rollback is exceeded.
rollback ::
     GetTip (BaseLedgerState' blk)
  => Word64
  ->        LedgerDB (BaseLedgerState blk)
  -> Maybe (LedgerDB (BaseLedgerState blk))
rollback n db@LedgerDB{..}
    | n <= ledgerDbMaxRollback db
    = Just db {
          ledgerDbCheckpoints = AS.dropNewest (fromIntegral n) ledgerDbCheckpoints
        }
    | otherwise
    = Nothing

{-------------------------------------------------------------------------------
  Updates
-------------------------------------------------------------------------------}

ledgerDbPush :: LedgerDBPush m c (BaseLedgerState blk) blk ValuesMK
             => LedgerDbCfg (BaseLedgerState blk)
             -> Ap m (BaseLedgerState blk) blk c
             ->    LedgerDB (BaseLedgerState blk)
             -> m (LedgerDB (BaseLedgerState blk))
ledgerDbPush cfg ap db =
    (\current' -> pushLedgerState (ledgerDbCfgSecParam cfg) current' db) <$>
      applyBlock (ledgerDbCfg cfg) ap db

-- | Push a bunch of blocks (oldest first)
ledgerDbPushMany :: LedgerDBPush m c (BaseLedgerState blk) blk ValuesMK
                 => LedgerDbCfg (BaseLedgerState blk)
                 -> [Ap m (BaseLedgerState blk) blk c]
                 ->    LedgerDB (BaseLedgerState blk)
                 -> m (LedgerDB (BaseLedgerState blk))
ledgerDbPushMany = repeatedlyM . ledgerDbPush

-- | Switch to a fork
ledgerDbSwitch :: LedgerDBPush m c (BaseLedgerState blk) blk ValuesMK
               => LedgerDbCfg (BaseLedgerState blk)
               -> Word64          -- ^ How many blocks to roll back
               -> [Ap m (BaseLedgerState blk) blk c]  -- ^ New blocks to apply
               ->                             LedgerDB (BaseLedgerState blk)
               -> m (Either ExceededRollback (LedgerDB (BaseLedgerState blk)))
ledgerDbSwitch cfg numRollbacks newBlocks db =
    case rollback numRollbacks db of
      Nothing ->
        return $ Left $ ExceededRollback {
            rollbackMaximum   = ledgerDbMaxRollback db
          , rollbackRequested = numRollbacks
          }
      Just db' ->
        Right <$> ledgerDbPushMany cfg newBlocks db'

{-------------------------------------------------------------------------------
  Support for testing
-------------------------------------------------------------------------------}

ledgerDbPush' :: LedgerDBPush Identity () (BaseLedgerState blk) blk ValuesMK
              => LedgerDbCfg (BaseLedgerState blk)
              -> blk
              -> LedgerDB (BaseLedgerState blk)
              -> LedgerDB (BaseLedgerState blk)
ledgerDbPush' cfg b = runIdentity . ledgerDbPush cfg (pureBlock b)

ledgerDbPushMany' :: LedgerDBPush Identity () (BaseLedgerState blk) blk ValuesMK
                  => LedgerDbCfg (BaseLedgerState blk)
                  -> [blk]
                  -> LedgerDB (BaseLedgerState blk)
                  -> LedgerDB (BaseLedgerState blk)
ledgerDbPushMany' cfg bs = runIdentity . ledgerDbPushMany cfg (map pureBlock bs)

ledgerDbSwitch' :: LedgerDBPush Identity () (BaseLedgerState blk) blk ValuesMK
                => LedgerDbCfg (BaseLedgerState blk)
                -> Word64
                -> [blk]
                ->        LedgerDB (BaseLedgerState blk)
                -> Maybe (LedgerDB (BaseLedgerState blk))
ledgerDbSwitch' cfg n bs db =
    case runIdentity $ ledgerDbSwitch cfg n (map pureBlock bs) db of
      Left  ExceededRollback{} -> Nothing
      Right db'                -> Just db'
