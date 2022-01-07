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
data instance LedgerDB (LedgerState Old blk) = LedgerDB {
  ledgerDbCheckpoints :: AnchoredSeq
                         (WithOrigin SlotNo)
                         (Checkpoint blk)
                         (Checkpoint blk)
  }
  deriving (Generic)

deriving instance Eq       (LedgerState Old blk ValuesMK) => Eq       (LedgerDB (LedgerState Old blk))
deriving instance NoThunks (LedgerState Old blk ValuesMK) => NoThunks (LedgerDB (LedgerState Old blk))

instance IsLedger (LedgerState Old blk) => GetTip (LedgerDB (LedgerState Old blk)) where
  getTip = castPoint . getTip . ledgerDbCurrent

-- | Internal newtype wrapper around a ledger state @l@ so that we can define a
-- non-blanket 'Anchorable' instance.
newtype Checkpoint blk = Checkpoint {
      unCheckpoint :: LedgerState Old blk ValuesMK
    }
  deriving (Generic)
deriving instance Eq                (LedgerState Old blk ValuesMK) => Eq       (Checkpoint blk)
deriving anyclass instance NoThunks (LedgerState Old blk ValuesMK) => NoThunks (Checkpoint blk)
instance ShowLedgerState (LedgerState Old blk) => Show (Checkpoint blk) where
  showsPrec = error "showsPrec @CheckPoint"

instance GetTip (LedgerState Old blk ValuesMK)
         => Anchorable (WithOrigin SlotNo) (Checkpoint blk) (Checkpoint blk) where
  asAnchor = id
  getAnchorMeasure _ = getTipSlot . unCheckpoint

{-------------------------------------------------------------------------------
  LedgerDB proper
-------------------------------------------------------------------------------}

ledgerDbWithAnchor ::
     GetTip (LedgerState Old blk ValuesMK)
  => (LedgerState Old blk) ValuesMK
  -> LedgerDB (LedgerState Old blk)
ledgerDbWithAnchor anchor = LedgerDB {
      ledgerDbCheckpoints = Empty (Checkpoint anchor)
    }

{-------------------------------------------------------------------------------
  Block application
-------------------------------------------------------------------------------}

pureBlock :: blk -> Ap m (LedgerState Old blk) blk ()
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
  ReapplyVal ::           blk -> Ap m (LedgerState Old blk) blk ( )
  ApplyVal   ::           blk -> Ap m (LedgerState Old blk) blk (                       ThrowsLedgerError m (LedgerState Old blk) blk)
  ReapplyRef :: RealPoint blk -> Ap m (LedgerState Old blk) blk (ResolvesBlocks m blk)
  ApplyRef   :: RealPoint blk -> Ap m (LedgerState Old blk) blk (ResolvesBlocks m blk , ThrowsLedgerError m (LedgerState Old blk) blk)

  -- | 'Weaken' increases the constraint on the monad @m@.
  --
  -- This is primarily useful when combining multiple 'Ap's in a single
  -- homogeneous structure.
  Weaken :: (c' => c) => Ap m (LedgerState Old blk) blk c -> Ap m (LedgerState Old blk) blk c'

{-------------------------------------------------------------------------------
  Internal utilities for 'Ap'
-------------------------------------------------------------------------------}

-- | Apply block to the current ledger state
--
-- We take in the entire 'LedgerDB' because we record that as part of errors.
applyBlock :: forall blk c m .
              ApplyBlockC m c (LedgerState Old blk) blk
           => LedgerCfg (LedgerState Old blk)
           -> Ap m (LedgerState Old blk) blk c
           -> LedgerDB (LedgerState Old blk)
           -> m (LedgerState Old blk (Output (LedgerState Old blk)))
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
--(LedgerState Old blk) ValuesMK
ledgerDbCurrent ::
     GetTip (LedgerState Old blk ValuesMK)
  => LedgerDB (LedgerState Old blk)
  -> LedgerState Old blk ValuesMK
ledgerDbCurrent = either unCheckpoint unCheckpoint . AS.head . ledgerDbCheckpoints


-- | Information about the state of the ledger at the anchor
ledgerDbAnchor ::
     LedgerDB (LedgerState Old blk)
  -> LedgerState Old blk ValuesMK
ledgerDbAnchor = unCheckpoint . AS.anchor . ledgerDbCheckpoints

-- | All snapshots currently stored by the ledger DB (new to old)
--
-- This also includes the snapshot at the anchor. For each snapshot we also
-- return the distance from the tip.
ledgerDbSnapshots ::
     LedgerDB (LedgerState Old blk)
  -> [(Word64, LedgerState Old blk ValuesMK)]
ledgerDbSnapshots db =
    zip
      [0..]
      (map unCheckpoint (AS.toNewestFirst $ ledgerDbCheckpoints db)
        <> [unCheckpoint (AS.anchor $ ledgerDbCheckpoints db)])


-- | How many blocks can we currently roll back?
ledgerDbMaxRollback ::
     GetTip (LedgerState Old blk ValuesMK)
  => LedgerDB (LedgerState Old blk)
  -> Word64
ledgerDbMaxRollback db = fromIntegral (AS.length $ ledgerDbCheckpoints db)


-- | Reference to the block at the tip of the chain
ledgerDbTip ::
     IsLedger (LedgerState Old blk)
  => LedgerDB (LedgerState Old blk)
  -> Point (LedgerState Old blk)
ledgerDbTip = castPoint . getTip . ledgerDbCurrent

-- | Have we seen at least @k@ blocks?
ledgerDbIsSaturated ::
     GetTip (LedgerState Old blk ValuesMK)
  => SecurityParam
  -> LedgerDB (LedgerState Old blk)
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
     , IsLedger (LedgerState Old blk)
     )
  => Point blk
  -> LedgerDB (LedgerState Old blk)
  -> Maybe (LedgerState Old blk ValuesMK)
ledgerDbPast pt db = ledgerDbCurrent <$> ledgerDbPrefix pt db

ledgerDbPrefix ::
     ( HasHeader blk
     , IsLedger (LedgerState Old blk)
     )
  => Point blk
  ->        LedgerDB (LedgerState Old blk)
  -> Maybe (LedgerDB (LedgerState Old blk))
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
     GetTip (LedgerState Old blk ValuesMK)
  => SecurityParam
  -> LedgerDB (LedgerState Old blk)
  -> LedgerDB (LedgerState Old blk)
ledgerDbPrune (SecurityParam k) db = db {
      ledgerDbCheckpoints = AS.anchorNewest k (ledgerDbCheckpoints db)
    }

{-------------------------------------------------------------------------------
  Internal updates
-------------------------------------------------------------------------------}

-- | Push an updated ledger state
pushLedgerState ::
     (GetTip (LedgerState Old blk ValuesMK))
  => SecurityParam
  -> LedgerState Old blk ValuesMK  -- ^ Updated ledger state
  -> LedgerDB (LedgerState Old blk)
  -> LedgerDB (LedgerState Old blk)
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
     GetTip (LedgerState Old blk ValuesMK)
  => Word64
  ->        LedgerDB (LedgerState Old blk)
  -> Maybe (LedgerDB (LedgerState Old blk))
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

ledgerDbPush :: LedgerDBPush m c (LedgerState Old blk) blk ValuesMK
             => LedgerDbCfg (LedgerState Old blk)
             -> Ap m (LedgerState Old blk) blk c
             ->    LedgerDB (LedgerState Old blk)
             -> m (LedgerDB (LedgerState Old blk))
ledgerDbPush cfg ap db =
    (\current' -> pushLedgerState (ledgerDbCfgSecParam cfg) current' db) <$>
      applyBlock (ledgerDbCfg cfg) ap db

-- | Push a bunch of blocks (oldest first)
ledgerDbPushMany :: LedgerDBPush m c (LedgerState Old blk) blk ValuesMK
                 => LedgerDbCfg (LedgerState Old blk)
                 -> [Ap m (LedgerState Old blk) blk c]
                 ->    LedgerDB (LedgerState Old blk)
                 -> m (LedgerDB (LedgerState Old blk))
ledgerDbPushMany = repeatedlyM . ledgerDbPush

-- | Switch to a fork
ledgerDbSwitch :: LedgerDBPush m c (LedgerState Old blk) blk ValuesMK
               => LedgerDbCfg (LedgerState Old blk)
               -> Word64          -- ^ How many blocks to roll back
               -> [Ap m (LedgerState Old blk) blk c]  -- ^ New blocks to apply
               ->                             LedgerDB (LedgerState Old blk)
               -> m (Either ExceededRollback (LedgerDB (LedgerState Old blk)))
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

ledgerDbPush' :: LedgerDBPush Identity () (LedgerState Old blk) blk ValuesMK
              => LedgerDbCfg (LedgerState Old blk)
              -> blk
              -> LedgerDB (LedgerState Old blk)
              -> LedgerDB (LedgerState Old blk)
ledgerDbPush' cfg b = runIdentity . ledgerDbPush cfg (pureBlock b)

ledgerDbPushMany' :: LedgerDBPush Identity () (LedgerState Old blk) blk ValuesMK
                  => LedgerDbCfg (LedgerState Old blk)
                  -> [blk]
                  -> LedgerDB (LedgerState Old blk)
                  -> LedgerDB (LedgerState Old blk)
ledgerDbPushMany' cfg bs = runIdentity . ledgerDbPushMany cfg (map pureBlock bs)

ledgerDbSwitch' :: LedgerDBPush Identity () (LedgerState Old blk) blk ValuesMK
                => LedgerDbCfg (LedgerState Old blk)
                -> Word64
                -> [blk]
                ->        LedgerDB (LedgerState Old blk)
                -> Maybe (LedgerDB (LedgerState Old blk))
ledgerDbSwitch' cfg n bs db =
    case runIdentity $ ledgerDbSwitch cfg n (map pureBlock bs) db of
      Left  ExceededRollback{} -> Nothing
      Right db'                -> Just db'
