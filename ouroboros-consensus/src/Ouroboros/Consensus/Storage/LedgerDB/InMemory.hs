{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveAnyClass         #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE QuantifiedConstraints  #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE EmptyDataDeriving      #-}

{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DerivingStrategies      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Ouroboros.Consensus.Storage.LedgerDB.InMemory (
    -- * LedgerDB proper
    LedgerDbCfg (..)
  , ledgerDbWithAnchor
    -- ** opaque
  , LedgerDB
    -- ** Serialisation
  , decodeSnapshotBackwardsCompatible
  , encodeSnapshot
    -- ** Queries
  , ledgerDbAnchor
  , ledgerDbBimap
  , ledgerDbCurrent
  , ledgerDbPast
  , ledgerDbPrefix
  , ledgerDbPrune
  , ledgerDbSnapshots
  , ledgerDbTip
    -- ** Running updates
  , AnnLedgerError (..)
  , New.Ap(..)
  , ResolveBlock
  , ResolvesBlocks (..)
  , ThrowsLedgerError (..)
  , defaultResolveBlocks
  , defaultResolveWithErrors
  , defaultThrowLedgerErrors
    -- ** Updates
  , ExceededRollback (..)
  , ledgerDbPush
  , ledgerDbPushMany
  , ledgerDbSwitch
    -- * Exports for the benefit of tests
    -- ** Additional queries
  , ledgerDbIsSaturated
  , ledgerDbMaxRollback
    -- ** Pure API
  , ledgerDbPush'
  , ledgerDbPushMany'
  , ledgerDbSwitch'
  ) where

import           Codec.Serialise.Decoding (Decoder)
import qualified Codec.Serialise.Decoding as Dec
import           Codec.Serialise.Encoding (Encoding)
import           Data.Word
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)
import           Control.Exception
import           Data.Coerce
import           Control.Monad.Identity hiding (ap)
import qualified Data.Map.Strict as Map

import           Ouroboros.Network.AnchoredSeq (AnchoredSeq (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Util
import           Ouroboros.Consensus.Util.CBOR (decodeWithOrigin)
import           Ouroboros.Consensus.Util.Versioned

import           Ouroboros.Consensus.Storage.LedgerDB.InMemory.Base
import qualified Ouroboros.Consensus.Storage.LedgerDB.InMemory.Old as Old
import qualified Ouroboros.Consensus.Storage.LedgerDB.InMemory.New as New
import Data.Kind

{-------------------------------------------------------------------------------
  Ledger DB types
-------------------------------------------------------------------------------}

data instance LedgerDB (LedgerState Both blk) = LedgerDB {
    ledgerDbOld :: Old.LedgerDB (LedgerState Old blk)
  , ledgerDbNew :: New.LedgerDB (LedgerState New blk)
  }
  deriving (Generic)

deriving instance (Eq       (LedgerDB (LedgerState Old blk)), Eq (LedgerDB (LedgerState New blk)))       => Eq       (LedgerDB (LedgerState Both blk))
deriving instance (NoThunks (LedgerDB (LedgerState Old blk)), NoThunks (LedgerDB (LedgerState New blk))) => NoThunks (LedgerDB (LedgerState Both blk))

instance ShowLedgerState l => Show (LedgerDB l) where
  showsPrec = error "showsPrec @LedgerDB"

{-------------------------------------------------------------------------------
  LedgerDB proper
-------------------------------------------------------------------------------}

-- | Ledger DB starting at the specified ledger state
ledgerDbWithAnchor ::
     (GetTip ((LedgerState Old blk) ValuesMK), GetTip ((LedgerState New blk) EmptyMK))
  => (LedgerState Both blk (BaseLedgerStateMK (LedgerState New blk)))
  -> LedgerDB (LedgerState Both blk)
ledgerDbWithAnchor (LedgerState old new) = LedgerDB {
      ledgerDbOld = Old.ledgerDbWithAnchor old
    , ledgerDbNew = New.ledgerDbWithAnchor new
    }

{-------------------------------------------------------------------------------
  Internal utilities for 'Ap'
-------------------------------------------------------------------------------}

pureBlock :: blk -> Ap m (LedgerState Both blk) blk (New.ReadsKeySets m (New.BaseLedgerState blk))
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
  ReapplyVal ::           blk -> Ap m (LedgerState Both blk) blk ( New.ReadsKeySets m (New.BaseLedgerState blk))
  ApplyVal   ::           blk -> Ap m (LedgerState Both blk) blk ( New.ReadsKeySets m (New.BaseLedgerState blk)
                                                                 , ThrowsLedgerError m (Old.BaseLedgerState blk) blk
                                                                 , ThrowsLedgerError m (New.BaseLedgerState blk) blk)
  ReapplyRef :: RealPoint blk -> Ap m (LedgerState Both blk) blk ( ResolvesBlocks m blk
                                                                 , New.ReadsKeySets m (New.BaseLedgerState blk)
                                                                 )
  ApplyRef   :: RealPoint blk -> Ap m (LedgerState Both blk) blk ( ResolvesBlocks m blk
                                                                 , ThrowsLedgerError m (Old.BaseLedgerState blk) blk
                                                                 , ThrowsLedgerError m (New.BaseLedgerState blk) blk
                                                                 , New.ReadsKeySets m (New.BaseLedgerState blk)
                                                                 )

  -- | 'Weaken' increases the constraint on the monad @m@.
  --
  -- This is primarily useful when combining multiple 'Ap's in a single
  -- homogeneous structure.
  Weaken :: (c' => c) => Ap m (LedgerState Both blk) blk c -> Ap m (LedgerState Both blk) blk c'

apToOldAp :: Ap m (LedgerState Both blk) blk c -> Old.Ap m (Old.BaseLedgerState blk) blk c
apToOldAp (ApplyVal b)   = Old.Weaken $ Old.ApplyVal b
apToOldAp (ReapplyVal b) = Old.Weaken $ Old.ReapplyVal b
apToOldAp (ApplyRef b)   = Old.Weaken $ Old.ApplyRef b
apToOldAp (ReapplyRef b) = Old.Weaken $ Old.ReapplyRef b
apToOldAp (Weaken ap)    = Old.Weaken $ apToOldAp ap

apToNewAp :: Ap m (LedgerState Both blk) blk c -> New.Ap m (New.BaseLedgerState blk) blk c
apToNewAp (ApplyVal b)   = New.Weaken $ New.ApplyVal b
apToNewAp (ReapplyVal b) = New.Weaken $ New.ReapplyVal b
apToNewAp (ApplyRef b)   = New.Weaken $ New.ApplyRef b
apToNewAp (ReapplyRef b) = New.Weaken $ New.ReapplyRef b
apToNewAp (Weaken ap)    = New.Weaken $ apToNewAp ap

_applyBlock :: forall m c blk
            . ( ApplyBlockC m c (Old.BaseLedgerState blk) blk
              , ApplyBlockC m c (New.BaseLedgerState blk) blk
              , LedgerCfg (LedgerState Both blk) ~ LedgerCfg (Old.BaseLedgerState blk)
              , LedgerCfg (LedgerState Both blk) ~ LedgerCfg (New.BaseLedgerState blk)
              , Output (Old.BaseLedgerState blk) ~ ValuesMK
              , Output (New.BaseLedgerState blk) ~ TrackingMK
              )
           => LedgerCfg (LedgerState Both blk)
           -> Ap m (LedgerState Both blk) blk c
           -> LedgerDB (LedgerState Both blk)
           -> m ( Old.BaseLedgerState' blk
                , New.BaseLedgerState blk TrackingMK)
_applyBlock cfg ap LedgerDB{..} = do
  old <- Old.applyBlock cfg (apToOldAp ap) ledgerDbOld
  new <- New.applyBlock cfg (apToNewAp ap) ledgerDbNew
  return $ (old, new)

{-------------------------------------------------------------------------------
  Queries
-------------------------------------------------------------------------------}

ledgerDbCurrent ::
     GetTip (LedgerState Old blk ValuesMK)
  => LedgerDB (LedgerState Both blk)
  -> (  (LedgerState Old blk) ValuesMK
      , (LedgerState New blk) EmptyMK)
ledgerDbCurrent LedgerDB{..} = (Old.ledgerDbCurrent ledgerDbOld, New.ledgerDbCurrent ledgerDbNew)

ledgerDbAnchor ::
     LedgerDB (LedgerState Both blk)
  -> ( (LedgerState Old blk) ValuesMK
     , (LedgerState New blk) EmptyMK)
ledgerDbAnchor LedgerDB{..} = (Old.ledgerDbAnchor ledgerDbOld, New.ledgerDbAnchor ledgerDbNew)

ledgerDbSnapshots ::
     LedgerDB (LedgerState Both blk)
  -> [(Word64, ( (LedgerState Old blk) ValuesMK
               , (LedgerState New blk) EmptyMK))]
ledgerDbSnapshots LedgerDB{..} =
  let mOld = Map.fromList $ Old.ledgerDbSnapshots ledgerDbOld
      mNew = Map.fromList $ New.ledgerDbSnapshots ledgerDbNew
  in Map.toList $ Map.intersectionWith (,) mOld mNew

ledgerDbMaxRollback ::
     GetTip (LedgerState Old blk ValuesMK)
  => LedgerDB (LedgerState Both blk)
  -> Word64
ledgerDbMaxRollback LedgerDB{..} =
  let l1 = Old.ledgerDbMaxRollback ledgerDbOld
      l2 = New.ledgerDbMaxRollback ledgerDbNew
  in
    assert (l1 == l2) l1

ledgerDbTip ::
     ( GetTip (LedgerState New blk EmptyMK)
     , GetTip (LedgerState Old blk ValuesMK)
     )
  => LedgerDB (LedgerState Both blk)
  -> (Point (LedgerState Old blk ValuesMK), Point (LedgerState New blk EmptyMK))
ledgerDbTip db =
  let (o,n) = ledgerDbCurrent db
  in
    (castPoint . getTip $ o,  castPoint . getTip $ n)

ledgerDbIsSaturated ::
     GetTip (LedgerState Old blk ValuesMK)
  => SecurityParam
  -> LedgerDB (LedgerState Both blk)
  -> Bool
ledgerDbIsSaturated (SecurityParam k) db =
    ledgerDbMaxRollback db >= k

ledgerDbPast ::
     ( HasHeader blk
     , IsLedger (LedgerState New blk)
     , IsLedger (LedgerState Old blk)
     )
  => Point blk
  -> LedgerDB (LedgerState Both blk)
  -> Maybe ((LedgerState Old blk) ValuesMK, (LedgerState New blk) EmptyMK)
ledgerDbPast pt LedgerDB{..} = (,) <$> Old.ledgerDbPast pt ledgerDbOld <*> New.ledgerDbPast pt ledgerDbNew

ledgerDbPrefix ::
     ( HasHeader blk
     , IsLedger (LedgerState Old blk)
     , IsLedger (LedgerState New blk)
     )
  => Point blk
  ->        LedgerDB (LedgerState Both blk)
  -> Maybe (LedgerDB (LedgerState Both blk))
ledgerDbPrefix pt LedgerDB{..} = do
  old <- Old.ledgerDbPrefix pt ledgerDbOld
  new <- New.ledgerDbPrefix pt ledgerDbNew
  return $ LedgerDB old new


-- | Transform the underlying 'AnchoredSeq' using the given functions.
ledgerDbBimap ::
     (l EmptyMK -> a)
  -> (l EmptyMK -> b)
  -> LedgerDB l
  -> AnchoredSeq (WithOrigin SlotNo) a b
ledgerDbBimap _f _g =
    -- Instead of exposing 'ledgerDbCheckpoints' directly, this function hides
    -- the internal 'Checkpoint' type.
    -- AS.bimap (f . unCheckpoint) (g . unCheckpoint) . ledgerDbCheckpoints
  undefined

ledgerDbPrune ::
     GetTip (LedgerState Old blk ValuesMK)
  => SecurityParam
  -> LedgerDB (LedgerState Both blk)
  -> LedgerDB (LedgerState Both blk)
ledgerDbPrune s LedgerDB{..} = LedgerDB (Old.ledgerDbPrune s ledgerDbOld) (New.ledgerDbPrune s ledgerDbNew)


 -- NOTE: we must inline 'ledgerDbPrune' otherwise we get unexplained thunks in
 -- 'LedgerDB' and thus a space leak. Alternatively, we could disable the
 -- @-fstrictness@ optimisation (enabled by default for -O1). See #2532.
{-# INLINE ledgerDbPrune #-}
{-# LANGUAGE DerivingStrategies #-}

{-------------------------------------------------------------------------------
  Internal updates
-------------------------------------------------------------------------------}

-- | Push an updated ledger state
_pushLedgerState ::
     ( Output (LedgerState Old blk) ~ ValuesMK
     , Output (LedgerState New blk) ~ TrackingMK
     , GetTip (LedgerState Old blk ValuesMK)
     )
  => SecurityParam
  -> ( (LedgerState Old blk) (Output (LedgerState Old blk))
     , (LedgerState New blk) (Output (LedgerState New blk))) -- ^ Updated ledger state
  -> LedgerDB (LedgerState Both blk) -> LedgerDB (LedgerState Both blk)
_pushLedgerState secParam (currentOld, currentNew) LedgerDB{..}  =
    LedgerDB (Old.pushLedgerState secParam currentOld ledgerDbOld)
             (New.pushLedgerState secParam currentNew ledgerDbNew)

{-------------------------------------------------------------------------------
  Internal: rolling back
-------------------------------------------------------------------------------}

-- | Rollback
--
-- Returns 'Nothing' if maximum rollback is exceeded.
_rollback ::
     GetTip (LedgerState Old blk ValuesMK)
  => Word64
  ->        LedgerDB (LedgerState Both blk)
  -> Maybe (LedgerDB (LedgerState Both blk))
_rollback n LedgerDB{..} = LedgerDB <$> Old.rollback n ledgerDbOld <*> New.rollback n ledgerDbNew

{-------------------------------------------------------------------------------
  Updates
-------------------------------------------------------------------------------}

ledgerDbPush :: forall m c blk
              . ( LedgerDBPush m c (Old.BaseLedgerState blk) blk ValuesMK
                , LedgerDBPush m c (New.BaseLedgerState blk) blk TrackingMK
                , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                )
             => LedgerDbCfg (LedgerState Both blk)
             -> Ap m (LedgerState Both blk) blk c
             ->    LedgerDB (LedgerState Both blk)
             -> m (LedgerDB (LedgerState Both blk))
ledgerDbPush cfg ap LedgerDB{..} =
      LedgerDB
  <$> Old.ledgerDbPush (coerce cfg) (apToOldAp ap) ledgerDbOld
  <*> New.ledgerDbPush (coerce cfg) (apToNewAp ap) ledgerDbNew

    -- (\current' -> pushLedgerState (ledgerDbCfgSecParam cfg) current' db) <$>
    --   applyBlock (ledgerDbCfg cfg) ap db

-- | Push a bunch of blocks (oldest first)
ledgerDbPushMany ::
                ( LedgerDBPush m c (Old.BaseLedgerState blk) blk ValuesMK
                , LedgerDBPush m c (New.BaseLedgerState blk) blk TrackingMK
                , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                )
                => LedgerDbCfg (LedgerState Both blk)
                -> [Ap m (LedgerState Both blk) blk c]
                ->    LedgerDB (LedgerState Both blk)
                -> m (LedgerDB (LedgerState Both blk))
ledgerDbPushMany = repeatedlyM . ledgerDbPush

-- | Switch to a fork
ledgerDbSwitch ::
                ( LedgerDBPush m c (Old.BaseLedgerState blk) blk ValuesMK
                , LedgerDBPush m c (New.BaseLedgerState blk) blk TrackingMK
                , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                )
               => LedgerDbCfg (LedgerState Both blk)
               -> Word64          -- ^ How many blocks to roll back
               -> [Ap m (LedgerState Both blk) blk c]  -- ^ New blocks to apply
               ->                             LedgerDB (LedgerState Both blk)
               -> m (Either ExceededRollback (LedgerDB (LedgerState Both blk)))
ledgerDbSwitch cfg numRollbacks newBlocks LedgerDB{..} = do
  old <- Old.ledgerDbSwitch (coerce cfg) numRollbacks (map apToOldAp newBlocks) ledgerDbOld
  new <- New.ledgerDbSwitch (coerce cfg) numRollbacks (map apToNewAp newBlocks) ledgerDbNew
  return $ LedgerDB <$> old <*> new

{-------------------------------------------------------------------------------
  LedgerDB Config
-------------------------------------------------------------------------------}

instance GetTip (LedgerDB (LedgerState Both blk)) where
  getTip = undefined --castPoint . getTip . ledgerDbCurrent

{-------------------------------------------------------------------------------
  Support for testing
-------------------------------------------------------------------------------}

ledgerDbPush' :: ( New.TestingLedgerDBPush (New.BaseLedgerState blk) blk TrackingMK
                 , LedgerDBPush Identity () (Old.BaseLedgerState blk) blk ValuesMK
                 , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                 , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                 )
              => LedgerDbCfg (LedgerState Both blk)
              -> blk
              -> LedgerDB (LedgerState Both blk)
              -> LedgerDB (LedgerState Both blk)
ledgerDbPush' cfg b LedgerDB{..} =
  LedgerDB (Old.ledgerDbPush' (coerce cfg) b ledgerDbOld)
           (New.ledgerDbPush' (coerce cfg) b ledgerDbNew)

ledgerDbPushMany' :: ( New.TestingLedgerDBPush (New.BaseLedgerState blk) blk TrackingMK
                     , LedgerDBPush Identity () (Old.BaseLedgerState blk) blk ValuesMK
                     , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                     , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                     )
                  => LedgerDbCfg (LedgerState Both blk)
                  -> [blk]
                  -> LedgerDB (LedgerState Both blk)
                  -> LedgerDB (LedgerState Both blk)
ledgerDbPushMany' cfg bs LedgerDB{..} =
  LedgerDB (Old.ledgerDbPushMany' (coerce cfg) bs ledgerDbOld)
           (New.ledgerDbPushMany' (coerce cfg) bs ledgerDbNew)

ledgerDbSwitch' :: ( New.TestingLedgerDBPush (New.BaseLedgerState blk) blk TrackingMK
                   , LedgerDBPush Identity () (Old.BaseLedgerState blk) blk ValuesMK
                   , Coercible (LedgerDbCfg (LedgerState Both blk)) (LedgerDbCfg (LedgerState Old blk))
                   , Coercible (LedgerDbCfg (LedgerState Both blk))  (LedgerDbCfg (LedgerState New blk))
                   )
                => LedgerDbCfg (LedgerState Both blk)
                -> Word64
                -> [blk]
                ->        LedgerDB (LedgerState Both blk)
                -> Maybe (LedgerDB (LedgerState Both blk))
ledgerDbSwitch' cfg n bs LedgerDB{..} =
      LedgerDB
  <$> Old.ledgerDbSwitch' (coerce cfg) n bs ledgerDbOld
  <*> New.ledgerDbSwitch' (coerce cfg) n bs ledgerDbNew

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

-- | Version 1: uses versioning ('Ouroboros.Consensus.Util.Versioned') and only
-- encodes the ledger state @l@.
snapshotEncodingVersion1 :: VersionNumber
snapshotEncodingVersion1 = 1

-- | Encoder to be used in combination with 'decodeSnapshotBackwardsCompatible'.
encodeSnapshot :: (l -> Encoding) -> l -> Encoding
encodeSnapshot encodeLedger l =
    encodeVersion snapshotEncodingVersion1 (encodeLedger l)

-- | To remain backwards compatible with existing snapshots stored on disk, we
-- must accept the old format as well as the new format.
--
-- The old format:
-- * The tip: @WithOrigin (RealPoint blk)@
-- * The chain length: @Word64@
-- * The ledger state: @l@
--
-- The new format is described by 'snapshotEncodingVersion1'.
--
-- This decoder will accept and ignore them. The encoder ('encodeSnapshot') will
-- no longer encode them.
decodeSnapshotBackwardsCompatible ::
     forall l blk.
     Proxy blk
  -> (forall s. Decoder s l)
  -> (forall s. Decoder s (HeaderHash blk))
  -> forall s. Decoder s l
decodeSnapshotBackwardsCompatible _ decodeLedger decodeHash =
    decodeVersionWithHook
      decodeOldFormat
      [(snapshotEncodingVersion1, Decode decodeVersion1)]
  where
    decodeVersion1 :: forall s. Decoder s l
    decodeVersion1 = decodeLedger

    decodeOldFormat :: Maybe Int -> forall s. Decoder s l
    decodeOldFormat (Just 3) = do
        _ <- withOriginRealPointToPoint <$>
               decodeWithOrigin (decodeRealPoint @blk decodeHash)
        _ <- Dec.decodeWord64
        decodeLedger
    decodeOldFormat mbListLen =
        fail $
          "decodeSnapshotBackwardsCompatible: invalid start " <>
          show mbListLen
