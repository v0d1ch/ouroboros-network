{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}

module Ouroboros.Consensus.HardFork.Combinator.Info (
    -- * Era info
    LedgerEraInfo (..)
  , SingleEraInfo (..)
  ) where

import           Codec.Serialise (Serialise)
import           Data.Text (Text)
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks (..))
import Ouroboros.Consensus.Ledger.Abstract (Implementation)

{-------------------------------------------------------------------------------
  Era info
-------------------------------------------------------------------------------}

-- | Information about an era (mostly for type errors)
data SingleEraInfo (i :: Implementation) blk = SingleEraInfo {
      singleEraName :: !Text
    }
  deriving stock    (Generic, Eq, Show)
  deriving anyclass (NoThunks, Serialise)

-- | Additional newtype wrapper around 'SingleEraInfo'
--
-- This is primarily useful for use in error messages: it marks which era
-- info came from the ledger, and which came from a tx/block/header/etc.
newtype LedgerEraInfo (i :: Implementation) blk = LedgerEraInfo {
      getLedgerEraInfo :: SingleEraInfo i blk
    }
  deriving stock   (Eq, Show)
  deriving newtype (NoThunks, Serialise)
