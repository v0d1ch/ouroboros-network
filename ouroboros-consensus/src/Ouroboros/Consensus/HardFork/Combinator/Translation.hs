{-# LANGUAGE DataKinds   #-}
{-# LANGUAGE DerivingVia #-}

module Ouroboros.Consensus.HardFork.Combinator.Translation (
    -- * Translate from one era to the next
    EraTranslation (..)
  , trivialEraTranslation
  ) where

import           NoThunks.Class (NoThunks, OnlyCheckWhnfNamed (..))

import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.TypeFamilyWrappers

import           Ouroboros.Consensus.HardFork.Combinator.State.Types
import           Ouroboros.Consensus.HardFork.Combinator.Util.InPairs
                     (InPairs (..), RequiringBoth (..))

{-------------------------------------------------------------------------------
  Translate from one era to the next
-------------------------------------------------------------------------------}

data EraTranslation i xs = EraTranslation {
      translateLedgerState   :: InPairs (RequiringBoth (WrapLedgerConfig i)    (TranslateLedgerState i))       xs
    , translateChainDepState :: InPairs (RequiringBoth WrapConsensusConfig (Translate WrapChainDepState)) xs
    , translateLedgerView    :: InPairs (RequiringBoth (WrapLedgerConfig i)    (TranslateForecast (LedgerState i) WrapLedgerView)) xs
    }
  deriving NoThunks
       via OnlyCheckWhnfNamed "EraTranslation" (EraTranslation i xs)

trivialEraTranslation :: EraTranslation i '[blk]
trivialEraTranslation = EraTranslation {
      translateLedgerState   = PNil
    , translateLedgerView    = PNil
    , translateChainDepState = PNil
    }
