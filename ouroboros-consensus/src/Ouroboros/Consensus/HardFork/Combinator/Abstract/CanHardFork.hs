{-# LANGUAGE DataKinds               #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE FlexibleInstances       #-}
{-# LANGUAGE TypeOperators           #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Ouroboros.Consensus.HardFork.Combinator.Abstract.CanHardFork (CanHardFork (..)) where

import           Data.SOP.Strict
import           Data.Typeable

import           Ouroboros.Consensus.TypeFamilyWrappers
import           Ouroboros.Consensus.Util.SOP

import           Ouroboros.Consensus.HardFork.Combinator.Abstract.SingleEraBlock
import           Ouroboros.Consensus.HardFork.Combinator.InjectTxs
import           Ouroboros.Consensus.HardFork.Combinator.Protocol.ChainSel
import           Ouroboros.Consensus.HardFork.Combinator.Translation
import           Ouroboros.Consensus.HardFork.Combinator.Util.Functors
                     (Product2)
import           Ouroboros.Consensus.HardFork.Combinator.Util.InPairs (InPairs,
                     RequiringBoth)
import qualified Ouroboros.Consensus.HardFork.Combinator.Util.InPairs as InPairs
import           Ouroboros.Consensus.HardFork.Combinator.Util.Tails (Tails)
import qualified Ouroboros.Consensus.HardFork.Combinator.Util.Tails as Tails

{-------------------------------------------------------------------------------
  CanHardFork
-------------------------------------------------------------------------------}

class (All (SingleEraBlock i) xs, Typeable xs, IsNonEmpty xs) => CanHardFork i xs where
  hardForkEraTranslation :: EraTranslation i xs
  hardForkChainSel       :: Tails (AcrossEraSelection i) xs
  hardForkInjectTxs      ::
    InPairs
      ( RequiringBoth
          (WrapLedgerConfig i)
          (Product2 InjectTx InjectValidatedTx)
      )
      xs

instance SingleEraBlock i blk => CanHardFork i '[blk] where
  hardForkEraTranslation = trivialEraTranslation
  hardForkChainSel       = Tails.mk1
  hardForkInjectTxs      = InPairs.mk1
