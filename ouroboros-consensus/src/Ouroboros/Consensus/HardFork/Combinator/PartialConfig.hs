{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Ouroboros.Consensus.HardFork.Combinator.PartialConfig (
    HasPartialConsensusConfig (..)
  , HasPartialLedgerConfig (..)
    -- * Newtype wrappers
  , WrapPartialConsensusConfig (..)
  , WrapPartialLedgerConfig (..)
    -- * Convenience re-exports
  , EpochInfo (..)
  , Except
  , PastHorizonException
  ) where

import           Control.Monad.Except (Except)
import           Data.Kind (Type)
import           NoThunks.Class (NoThunks)

import           Cardano.Slotting.EpochInfo

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.HardFork.History.Qry (PastHorizonException)
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Protocol.Abstract

-- | Partial consensus config
class ( ConsensusProtocol p
      , NoThunks (PartialConsensusConfig p)
      ) => HasPartialConsensusConfig p where
  type PartialConsensusConfig p :: Type
  type PartialConsensusConfig p = ConsensusConfig p

  -- | Construct 'ConsensusConfig' from 'PartialConsensusConfig'
  --
  -- See comments for 'completeLedgerConfig' for some details about the
  -- 'EpochInfo'.
  completeConsensusConfig :: proxy p
                          -> EpochInfo (Except PastHorizonException)
                          -> PartialConsensusConfig p -> ConsensusConfig p

  default completeConsensusConfig :: (PartialConsensusConfig p ~ ConsensusConfig p)
                                  => proxy p
                                  -> EpochInfo (Except PastHorizonException)
                                  -> PartialConsensusConfig p -> ConsensusConfig p
  completeConsensusConfig _ _ = id

-- | Partial ledger config
class ( UpdateLedger i blk
      , NoThunks (PartialLedgerConfig i blk)
      ) => HasPartialLedgerConfig i blk where
  type PartialLedgerConfig i blk :: Type
  type PartialLedgerConfig i blk = LedgerConfig i blk

  -- | Construct 'LedgerConfig' from 'PartialLedgerCfg'
  --
  -- NOTE: The 'EpochInfo' provided will have limited range, any attempt to
  -- look past its horizon will result in a pure 'PastHorizonException'.
  -- The horizon is determined by the tip of the ledger /state/ (not view)
  -- from which the 'EpochInfo' is derived.
  --
  completeLedgerConfig :: proxy blk
                       -> EpochInfo (Except PastHorizonException)
                       -> PartialLedgerConfig i blk  -> LedgerConfig i blk
  default completeLedgerConfig :: (PartialLedgerConfig i blk ~ LedgerConfig i blk)
                               => proxy blk
                               -> EpochInfo (Except PastHorizonException)
                               -> PartialLedgerConfig i blk  -> LedgerConfig i blk
  completeLedgerConfig _ _ = id

{-------------------------------------------------------------------------------
  Newtype wrappers
-------------------------------------------------------------------------------}

newtype WrapPartialLedgerConfig    i blk = WrapPartialLedgerConfig    { unwrapPartialLedgerConfig    :: PartialLedgerConfig                   i blk  }
newtype WrapPartialConsensusConfig blk = WrapPartialConsensusConfig { unwrapPartialConsensusConfig :: PartialConsensusConfig (BlockProtocol blk) }

deriving instance NoThunks (PartialLedgerConfig                   i blk)  => NoThunks (WrapPartialLedgerConfig    i blk)
deriving instance NoThunks (PartialConsensusConfig (BlockProtocol blk)) => NoThunks (WrapPartialConsensusConfig blk)
