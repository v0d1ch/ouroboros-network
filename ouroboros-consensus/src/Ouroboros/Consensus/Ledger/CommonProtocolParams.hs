{-# LANGUAGE MultiParamTypeClasses #-}
module Ouroboros.Consensus.Ledger.CommonProtocolParams (CommonProtocolParams (..)) where

import           Data.Word (Word32)

import           Ouroboros.Consensus.Ledger.Abstract

-- | Ask the ledger for common protocol parameters.
class UpdateLedger i blk => CommonProtocolParams i blk where

  -- | The maximum header size in bytes according to the currently adopted
  -- protocol parameters of the ledger state.
  maxHeaderSize :: LedgerState i blk mk -> Word32

  -- | The maximum transaction size in bytes according to the currently
  -- adopted protocol parameters of the ledger state.
  maxTxSize :: LedgerState i blk mk -> Word32
