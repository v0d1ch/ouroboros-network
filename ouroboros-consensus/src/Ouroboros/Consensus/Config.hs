{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module Ouroboros.Consensus.Config (
    -- * The top-level node configuration
    TopLevelConfig (..)
  , castTopLevelConfig
  , mkTopLevelConfig
    -- ** Derived extraction functions
  , configBlock
  , configCodec
  , configConsensus
  , configLedger
  , configStorage
    -- ** Additional convenience functions
  , configSecurityParam
    -- * Re-exports
  , module Ouroboros.Consensus.Config.SecurityParam
  ) where

import           Data.Coerce
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)

import           Ouroboros.Consensus.Block.Abstract
import           Ouroboros.Consensus.Config.SecurityParam
import           Ouroboros.Consensus.Ledger.Basics
import           Ouroboros.Consensus.Protocol.Abstract

{-------------------------------------------------------------------------------
  Top-level config
-------------------------------------------------------------------------------}

-- | The top-level node configuration
data TopLevelConfig i blk = TopLevelConfig {
      topLevelConfigProtocol :: !(ConsensusConfig (BlockProtocol blk))
    , topLevelConfigLedger   :: !(LedgerConfig i blk)
    , topLevelConfigBlock    :: !(BlockConfig blk)
    , topLevelConfigCodec    :: !(CodecConfig blk)
    , topLevelConfigStorage  :: !(StorageConfig blk)
    }
  deriving (Generic)

instance ( ConsensusProtocol (BlockProtocol blk)
         , NoThunks (LedgerConfig  i blk)
         , NoThunks (BlockConfig   blk)
         , NoThunks (CodecConfig   blk)
         , NoThunks (StorageConfig blk)
         ) => NoThunks (TopLevelConfig i blk)

mkTopLevelConfig ::
     ConsensusConfig (BlockProtocol blk)
  -> LedgerConfig   i blk
  -> BlockConfig    blk
  -> CodecConfig    blk
  -> StorageConfig  blk
  -> TopLevelConfig i blk
mkTopLevelConfig = TopLevelConfig

configConsensus :: TopLevelConfig i blk -> ConsensusConfig (BlockProtocol blk)
configConsensus = topLevelConfigProtocol

configLedger :: TopLevelConfig i blk -> LedgerConfig i blk
configLedger = topLevelConfigLedger

configBlock  :: TopLevelConfig i blk -> BlockConfig  blk
configBlock = topLevelConfigBlock

configCodec  :: TopLevelConfig i blk -> CodecConfig  blk
configCodec = topLevelConfigCodec

configStorage  :: TopLevelConfig i blk -> StorageConfig blk
configStorage = topLevelConfigStorage

configSecurityParam :: ConsensusProtocol (BlockProtocol blk)
                    => TopLevelConfig i blk -> SecurityParam
configSecurityParam = protocolSecurityParam . configConsensus

castTopLevelConfig ::
     ( Coercible (ConsensusConfig (BlockProtocol blk))
                 (ConsensusConfig (BlockProtocol blk'))
     , LedgerConfig i blk ~ LedgerConfig i blk'
     , Coercible (BlockConfig   blk) (BlockConfig   blk')
     , Coercible (CodecConfig   blk) (CodecConfig   blk')
     , Coercible (StorageConfig blk) (StorageConfig blk')
     )
  => TopLevelConfig i blk -> TopLevelConfig i blk'
castTopLevelConfig TopLevelConfig{..} = TopLevelConfig{
      topLevelConfigProtocol = coerce topLevelConfigProtocol
    , topLevelConfigLedger   = topLevelConfigLedger
    , topLevelConfigBlock    = coerce topLevelConfigBlock
    , topLevelConfigCodec    = coerce topLevelConfigCodec
    , topLevelConfigStorage  = coerce topLevelConfigStorage
    }
