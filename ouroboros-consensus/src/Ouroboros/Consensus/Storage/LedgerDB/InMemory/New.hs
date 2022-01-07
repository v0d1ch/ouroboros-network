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
{-# LANGUAGE DerivingVia #-}
-- |

module Ouroboros.Consensus.Storage.LedgerDB.InMemory.New
  where

import           Control.Monad.Except hiding (ap)
import           Data.Functor.Identity
import           Data.Word
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks, OnlyCheckWhnfNamed(..))
import           Data.Kind
import           Control.Monad.Reader hiding (ap)

import           Cardano.Slotting.Slot

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Util

import           Ouroboros.Consensus.Storage.LedgerDB.InMemory.Base
import Ouroboros.Consensus.Storage.FS.API

{-------------------------------------------------------------------------------
  Ledger types
-------------------------------------------------------------------------------}

data instance LedgerDB (LedgerState New blk) = LedgerDB {
  ledgerDbChangelog :: DbChangelog (LedgerState New blk)
  }
  deriving (Generic)


deriving instance Eq       (LedgerState New blk EmptyMK) => Eq       (LedgerDB (LedgerState New blk))
deriving instance NoThunks (LedgerState New blk EmptyMK) => NoThunks (LedgerDB (LedgerState New blk))

instance IsLedger (LedgerState New blk) => GetTip (LedgerDB (LedgerState New blk)) where
  getTip = castPoint . getTip . ledgerDbCurrent

{-------------------------------------------------------------------------------
  LedgerDB proper
-------------------------------------------------------------------------------}

-- TODO: flushing the changelog will invalidate other copies of 'LedgerDB'. At
-- the moment the flush-locking concern is outside the scope of this module.
-- Clients need to ensure they flush in a safe manner.
--
ledgerDbFlush ::
     Monad m
  => (      DbChangelog (LedgerState New blk)
      -> m (DbChangelog (LedgerState New blk))
     )
  ->    LedgerDB (LedgerState New blk)
  -> m (LedgerDB (LedgerState New blk))
ledgerDbFlush changelogFlush db = do
  ledgerDbChangelog' <- changelogFlush (ledgerDbChangelog db)
  return $! db { ledgerDbChangelog = ledgerDbChangelog' }

ledgerDbWithAnchor ::
     GetTip (LedgerState New blk EmptyMK)
  => LedgerState New blk EmptyMK
  -> LedgerDB (LedgerState New blk)
ledgerDbWithAnchor anchor = LedgerDB {
      ledgerDbChangelog = initialDbChangelog (getTipSlot anchor) anchor
    }

{-------------------------------------------------------------------------------
  Block application
-------------------------------------------------------------------------------}

pureBlock :: blk -> Ap m (LedgerState New blk) blk (ReadsKeySets m (LedgerState New blk))
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
  ReapplyVal ::           blk -> Ap m (LedgerState New blk) blk ( ReadsKeySets m (LedgerState New blk) )
  ApplyVal   ::           blk -> Ap m (LedgerState New blk) blk ( ReadsKeySets m (LedgerState New blk)
                                            , ThrowsLedgerError m (LedgerState New blk) blk )
  ReapplyRef :: RealPoint blk -> Ap m (LedgerState New blk) blk ( ResolvesBlocks m blk
                                            , ReadsKeySets m (LedgerState New blk)
                                            )
  ApplyRef   :: RealPoint blk -> Ap m (LedgerState New blk) blk ( ResolvesBlocks m blk
                                            , ThrowsLedgerError m (LedgerState New blk) blk
                                            , ReadsKeySets m (LedgerState New blk)
                                            )

  -- | 'Weaken' increases the constraint on the monad @m@.
  --
  -- This is primarily useful when combining multiple 'Ap's in a single
  -- homogeneous structure.
  Weaken :: (c' => c) => Ap m (LedgerState New blk) blk c -> Ap m (LedgerState New blk) blk c'

{-------------------------------------------------------------------------------
  Internal utilities for 'Ap'
-------------------------------------------------------------------------------}

applyBlock :: forall m c blk
            . ApplyBlockC m c (LedgerState New blk) blk
           => LedgerCfg (LedgerState New blk)
           -> Ap m (LedgerState New blk) blk c
           -> LedgerDB (LedgerState New blk)
            -> m (LedgerState New blk (Output (LedgerState New blk)))
applyBlock cfg ap db = case ap of
    ReapplyVal b ->
        withBlockReadSets b $ \lh ->
          return $ tickThenReapply cfg b lh
    ApplyVal b ->
        withBlockReadSets b $ \lh ->
          either (throwLedgerError db (blockRealPoint b)) return $ runExcept $
             tickThenApply cfg b lh
    ReapplyRef r  -> do
      b <- resolveBlock r -- TODO: ask: would it make sense to recursively call applyBlock using ReapplyVal?
      withBlockReadSets b $ \lh ->
        return $
          tickThenReapply cfg b lh
    ApplyRef r -> do
      b <- resolveBlock r
      withBlockReadSets b $ \lh ->
        either (throwLedgerError db r) return $ runExcept $
          tickThenApply cfg b lh
    Weaken ap' ->
      applyBlock cfg ap' db
  where
    withBlockReadSets ::
         ReadsKeySets m (LedgerState New blk)
      => blk
      -> (      LedgerState New blk ValuesMK
          -> m (LedgerState New blk (Output (LedgerState New blk))))
      -> m (LedgerState New blk (Output (LedgerState New blk)))
    withBlockReadSets b f = do
      let ks = getBlockKeySets b :: TableKeySets (LedgerState New blk)
      let aks = rewindTableKeySetsImpl (ledgerDbChangelog db) ks :: RewoundTableKeySets (LedgerState New blk)
      urs <- readDb aks
      case withHydratedLedgerState urs f of
        Nothing ->
          -- We performed the rewind;read;forward sequence in this function. So
          -- the forward operation should not fail. If this is the case we're in
          -- the presence of a problem that we cannot deal with at this level,
          -- so we throw an error.
          --
          -- When we introduce pipelining, if the forward operation fails it
          -- could be because the DB handle was modified by a DB flush that took
          -- place when __after__ we read the unforwarded keys-set from disk.
          -- However, performing rewind;read;forward with the same __locked__
          -- changelog should always succeed.
          error "Changelog rewind;read;forward sequence failed."
        Just res -> res

    withHydratedLedgerState ::
         UnforwardedReadSets (LedgerState New blk)
      -> (LedgerState New blk ValuesMK -> a)
      -> Maybe a
    withHydratedLedgerState urs f = do
      rs <- forwardTableKeySetsImpl (ledgerDbChangelog db) urs
      return $ f $ withLedgerTables (ledgerDbCurrent db)  rs

{-------------------------------------------------------------------------------
  Queries
-------------------------------------------------------------------------------}

ledgerDbCurrent ::
     LedgerDB (LedgerState New blk)
  -> LedgerState New blk EmptyMK
ledgerDbCurrent = undefined . ledgerDbChangelog -- TODO

ledgerDbAnchor ::
     LedgerDB (LedgerState New blk)
  -> LedgerState New blk EmptyMK
ledgerDbAnchor = undefined . ledgerDbChangelog

ledgerDbSnapshots ::
     LedgerDB (LedgerState New blk)
  -> [(Word64, LedgerState New blk EmptyMK)]
ledgerDbSnapshots db = undefined $ ledgerDbChangelog db

ledgerDbMaxRollback ::
     LedgerDB (LedgerState New blk)
  -> Word64
ledgerDbMaxRollback _db = undefined

ledgerDbTip ::
     IsLedger (LedgerState New blk)
  => LedgerDB (LedgerState New blk)
  -> Point (LedgerState New blk)
ledgerDbTip = castPoint . getTip . ledgerDbCurrent

ledgerDbIsSaturated ::
     SecurityParam
  -> LedgerDB (LedgerState New blk)
  -> Bool
ledgerDbIsSaturated (SecurityParam k) db =
    ledgerDbMaxRollback db >= k

ledgerDbPast ::
     ( HasHeader blk
     , IsLedger (LedgerState New blk)
     )
  => Point blk
  -> LedgerDB (LedgerState New blk)
  -> Maybe (LedgerState New blk EmptyMK)
ledgerDbPast pt db = ledgerDbCurrent <$> ledgerDbPrefix pt db


-- | Get a prefix of the LedgerDB
--
--  \( O(\log(\min(i,n-i)) \)
--
-- When no ledger state (or anchor) has the given 'Point', 'Nothing' is
-- returned.
ledgerDbPrefix ::
     ( HasHeader blk
     , IsLedger (LedgerState New blk)
     )
  => Point blk
  ->        LedgerDB (LedgerState New blk)
  -> Maybe (LedgerDB (LedgerState New blk))
ledgerDbPrefix pt db
    | pt == castPoint (getTip (ledgerDbAnchor db))
    = Just $ ledgerDbWithAnchor $ ledgerDbAnchor db --  LedgerDBAnchor' New blk ------- LedgerState New blk EmptyMK
    | otherwise
    =  do
        return $ LedgerDB undefined

ledgerDbPrune ::
     SecurityParam
  -> LedgerDB (LedgerState New blk)
  -> LedgerDB (LedgerState New blk)
ledgerDbPrune (SecurityParam _k) _db =  undefined

{-------------------------------------------------------------------------------
  Internal updates
-------------------------------------------------------------------------------}

-- | Push an updated ledger state
pushLedgerState ::
     SecurityParam
  -> LedgerState New blk (Output (LedgerState New blk)) -- ^ Updated ledger state
  -> LedgerDB (LedgerState New blk)
  -> LedgerDB (LedgerState New blk)
pushLedgerState secParam _current' db  =
    ledgerDbPrune secParam $ db {
        ledgerDbChangelog = undefined
    }

{-------------------------------------------------------------------------------
  Internal: rolling back
-------------------------------------------------------------------------------}

-- | Rollback
--
-- Returns 'Nothing' if maximum rollback is exceeded.
rollback ::
     Word64
  ->        LedgerDB (LedgerState New blk)
  -> Maybe (LedgerDB (LedgerState New blk))
rollback n db
    | n <= ledgerDbMaxRollback db
    = undefined
    | otherwise
    = Nothing

{-------------------------------------------------------------------------------
  Updates
-------------------------------------------------------------------------------}

ledgerDbPush ::
     LedgerDBPush m c (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> Ap m (LedgerState New blk) blk c
  ->    LedgerDB (LedgerState New blk)
  -> m (LedgerDB (LedgerState New blk))
ledgerDbPush cfg ap db =
    (\current' -> pushLedgerState (ledgerDbCfgSecParam cfg) current' db) <$>
      applyBlock (ledgerDbCfg cfg) ap db

-- | Push a bunch of blocks (oldest first)
ledgerDbPushMany ::
     LedgerDBPush m c (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> [Ap m (LedgerState New blk) blk c]
  ->    LedgerDB (LedgerState New blk)
  -> m (LedgerDB (LedgerState New blk))
ledgerDbPushMany = repeatedlyM . ledgerDbPush

-- | Switch to a fork
ledgerDbSwitch ::
     LedgerDBPush m c (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> Word64          -- ^ How many blocks to roll back
  -> [Ap m (LedgerState New blk) blk c]  -- ^ New blocks to apply
  ->                             LedgerDB (LedgerState New blk)
  -> m (Either ExceededRollback (LedgerDB (LedgerState New blk)))
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

ledgerDbPush' ::
     TestingLedgerDBPush (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> blk
  -> LedgerDB (LedgerState New blk)
  -> LedgerDB (LedgerState New blk)
ledgerDbPush' cfg b = runIdentity . ledgerDbPush cfg (pureBlock b)

ledgerDbPushMany' ::
     TestingLedgerDBPush (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> [blk]
  -> LedgerDB (LedgerState New blk)
  -> LedgerDB (LedgerState New blk)
ledgerDbPushMany' cfg bs = runIdentity . ledgerDbPushMany cfg (map pureBlock bs)

ledgerDbSwitch' ::
     TestingLedgerDBPush (LedgerState New blk) blk TrackingMK
  => LedgerDbCfg (LedgerState New blk)
  -> Word64
  -> [blk]
  ->        LedgerDB (LedgerState New blk)
  -> Maybe (LedgerDB (LedgerState New blk))
ledgerDbSwitch' cfg n bs db =
    case runIdentity $ ledgerDbSwitch cfg n (map pureBlock bs) db of
      Left  ExceededRollback{} -> Nothing
      Right db'                -> Just db'

type TestingLedgerDBPush l blk mk = ( LedgerDBPush Identity () l blk mk
                                    , ReadsKeySets Identity l)

{-------------------------------------------------------------------------------
  HD Interface that I need (Could be moved to  Ouroboros.Consensus.Ledger.Basics )
-------------------------------------------------------------------------------}

data DbChangelog (l :: LedgerStateKind)
  deriving (Eq, Generic, NoThunks)

newtype RewoundTableKeySets l = RewoundTableKeySets (AnnTableKeySets l ()) -- KeySetSanityInfo l

initialDbChangelog
  :: WithOrigin SlotNo -> l EmptyMK -> DbChangelog l
initialDbChangelog = undefined

rewindTableKeySetsImpl
  :: DbChangelog l -> TableKeySets l -> RewoundTableKeySets l
rewindTableKeySetsImpl = undefined

newtype UnforwardedReadSets l = UnforwardedReadSets (AnnTableReadSets l ())

forwardTableKeySetsImpl
  :: DbChangelog l -> UnforwardedReadSets l -> Maybe (TableReadSets l)
forwardTableKeySetsImpl = undefined

extendDbChangelog
  :: SeqNo l
  -> l DiffMK
  -- -> Maybe (l SnapshotsMK) TOOD: We won't use this parameter in the first iteration.
  -> DbChangelog l
  -> DbChangelog l
extendDbChangelog = undefined

newtype SeqNo (state :: LedgerStateKind) = SeqNo { unSeqNo :: Word64 }
  deriving (Eq, Ord, Show)

class HasSeqNo (state :: LedgerStateKind) where
  stateSeqNo :: state table -> SeqNo state

class ReadsKeySets m l  where

  readDb :: ReadKeySets m l

type ReadKeySets m l = RewoundTableKeySets l -> m (UnforwardedReadSets l)

newtype DbReader m l a = DbReader { runDbReader :: ReaderT (ReadKeySets m l) m a}
  deriving newtype (Functor, Applicative, Monad)

instance ReadsKeySets (DbReader m l) l where
  readDb rks = DbReader $ ReaderT $ \f -> f rks

-- TODO: this is leaking details on how we want to compose monads at the higher levels.
instance (Monad m, ReadsKeySets m l) => ReadsKeySets (ReaderT r m) l where
  readDb = lift . readDb

instance (Monad m, ReadsKeySets m l) => ReadsKeySets (ExceptT e m) l where
  readDb = lift . readDb

defaultReadKeySets :: ReadKeySets m l -> DbReader m l a -> m a
defaultReadKeySets f dbReader = runReaderT (runDbReader dbReader) f

instance IsLedger l => HasSeqNo l where
  stateSeqNo l =
    case getTipSlot l of
      Origin        -> SeqNo 0
      At (SlotNo n) -> SeqNo (n + 1)


mkOnDiskLedgerStDb :: SomeHasFS m -> m (OnDiskLedgerStDb m l)
mkOnDiskLedgerStDb = undefined
  -- \(SomeHasFS fs) -> do
  --   dbhandle <- hOpen fs "ledgerStateDb"
  --   ...

  --   return OnDiskLedgerStDb
  --   { ...
  --     , readKeySets = Snapshots.readDb dbhandle

  --     }

-- | On disk ledger state API.
--
--
data OnDiskLedgerStDb m l =
  OnDiskLedgerStDb
  { rewindTableKeySets   :: () -- TODO: move the corresponding function from
                               -- InMemory here.
  , forwardTableKeySets  :: () -- TODO: ditto.

  , readKeySets :: RewoundTableKeySets l -> m (UnforwardedReadSets l)
   -- ^ Captures the handle. Implemented by Snapshots.readDb
   --
   -- TODO: consider unifying this with defaultReadKeySets. Why? Because we are always using
   -- 'defaultReadKeySets' with readKeySets.
  , flushDb     :: DbChangelog l -> m (DbChangelog l )
    -- ^ Flush the ledger DB when appropriate. We assume the implementation of
    -- this function will determine when to flush.
    --
    -- NOTE: Captures the handle and the flushing policy. Implemented by
    -- Snapshots.writeDb.
  , createRestorePoint :: DbChangelog l -> m ()
    -- ^ Captures the DbHandle. Implemented using createRestorePoint (proposed
    -- by Douglas). We need to take the current SeqNo for the on disk state from
    -- the DbChangelog.

    {- * other restore point ops ... -}
  , closeDb :: m ()
    -- ^ This closes the captured handle.
  }
  deriving NoThunks via OnlyCheckWhnfNamed "OnDiskLedgerStDb" (OnDiskLedgerStDb m l)
