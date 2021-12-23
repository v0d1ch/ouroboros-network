{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Ouroboros.Consensus.Ledger.Extended (
    -- * Extended ledger state
    ExtLedgerCfg (..)
  , ExtLedgerState (..)
  , ExtValidationError (..)
    -- * Serialisation
  , decodeExtLedgerState
  , encodeExtLedgerState
    -- * Casts
  , castExtLedgerState
    -- * Type family instances
  , LedgerTables (..)
  , Ticked1 (..)
    -- * MapKind
  , MapKind (..)
  , toEmptyMK
  ) where

import           Codec.CBOR.Decoding (Decoder)
import           Codec.CBOR.Encoding (Encoding)
import           Control.Monad.Except
import           Data.Coerce
import           Data.Functor ((<&>))
import           Data.Proxy
import           Data.Typeable
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import qualified Ouroboros.Consensus.Ledger.Basics as Basics
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Ticked

{-------------------------------------------------------------------------------
  Extended ledger state
-------------------------------------------------------------------------------}

toEmptyMK :: ExtLedgerState i blk mk -> ExtLedgerState i blk EmptyMK
toEmptyMK = error "toEmptyMK"

-- | Extended ledger state
--
-- This is the combination of the header state and the ledger state proper.
data ExtLedgerState i blk (mk :: MapKind) = ExtLedgerState {
      ledgerState :: !(LedgerState i blk mk)
    , headerState :: !(HeaderState blk)
    }
  deriving (Generic)

data ExtValidationError i blk =
    ExtValidationErrorLedger !(LedgerError i blk)
  | ExtValidationErrorHeader !(HeaderError blk)
  deriving (Generic)

instance (LedgerSupportsProtocol i blk, forall l. ApplyBlock l blk) => NoThunks (ExtValidationError i blk)

deriving instance LedgerSupportsProtocol i blk => Show (ExtValidationError    i blk)
deriving instance LedgerSupportsProtocol i blk => Eq   (ExtValidationError    i blk)

-- instance LedgerSupportsProtocol blk => ShowLedgerState (ExtLedgerState blk) where
--   showsLedgerState = error "showsLedgerState @ExtLedgerState"

-- | We override 'showTypeOf' to show the type of the block
--
-- This makes debugging a bit easier, as the block gets used to resolve all
-- kinds of type families.
instance (Typeable i, Typeable mk, LedgerSupportsProtocol i blk) => NoThunks (ExtLedgerState i blk mk) where
  showTypeOf _ = show $ typeRep (Proxy @(ExtLedgerState i blk mk))

deriving instance ( LedgerSupportsProtocol i blk
                  , Eq (ChainDepState (BlockProtocol blk))
                  ) => Eq (ExtLedgerState i blk mk)

{-------------------------------------------------------------------------------
  The extended ledger can behave like a ledger
-------------------------------------------------------------------------------}

data instance Ticked1 (ExtLedgerState i blk) mk = TickedExtLedgerState {
      tickedLedgerState :: Ticked1 (LedgerState i blk) mk
    , tickedLedgerView  :: Ticked (LedgerView (BlockProtocol blk))
    , tickedHeaderState :: Ticked (HeaderState blk)
    }

-- | " Ledger " configuration for the extended ledger
--
-- Since the extended ledger also does the consensus protocol validation, we
-- also need the consensus config.
newtype ExtLedgerCfg i blk = ExtLedgerCfg {
      getExtLedgerCfg :: TopLevelConfig i blk
    }
  deriving (Generic)

instance ( ConsensusProtocol (BlockProtocol blk)
         , NoThunks (BlockConfig   blk)
         , NoThunks (CodecConfig   blk)
         , NoThunks (LedgerConfig  i blk)
         , NoThunks (StorageConfig blk)
         ) => NoThunks (ExtLedgerCfg i blk)

type instance LedgerCfg (ExtLedgerState i blk) = ExtLedgerCfg i blk

type instance HeaderHash (ExtLedgerState i blk)    = HeaderHash (LedgerState i blk)
type instance HeaderHash (ExtLedgerState i blk mk) = HeaderHash (LedgerState i blk)

instance (HeaderHash (ExtLedgerState i blk mk) ~ HeaderHash blk, IsLedger (LedgerState i blk)) => GetTip (ExtLedgerState i blk mk) where
  getTip = castPoint . getTip . ledgerState

instance (HeaderHash (LedgerState i blk) ~ HeaderHash blk, IsLedger (LedgerState i blk)) => GetTip (Ticked1 (ExtLedgerState i blk) mk) where
  getTip = castPoint . getTip . tickedLedgerState

instance ( Eq (ExtValidationError i blk)
         , NoThunks (ExtValidationError i blk)
         , Show (ExtValidationError i blk)
         , ShowLedgerState (ExtLedgerState i blk)
         , Typeable i
         , IsLedger (LedgerState  i blk)
         , LedgerSupportsProtocol i blk
         )
      => IsLedger (ExtLedgerState i blk) where

  type Output (ExtLedgerState i blk) = Basics.Output (LedgerState i blk)

  type LedgerErr (ExtLedgerState i blk) = ExtValidationError i blk

  type AuxLedgerEvent (ExtLedgerState i blk) = AuxLedgerEvent (LedgerState i blk)

  applyChainTickLedgerResult cfg slot (ExtLedgerState ledger header) =
      castLedgerResult ledgerResult <&> \tickedLedgerState ->
      let tickedLedgerView :: Ticked (LedgerView (BlockProtocol blk))
          tickedLedgerView = protocolLedgerView lcfg tickedLedgerState

          tickedHeaderState :: Ticked (HeaderState blk)
          tickedHeaderState =
              tickHeaderState
                (configConsensus $ getExtLedgerCfg cfg)
                tickedLedgerView
                slot
                header
      in TickedExtLedgerState {..}
    where
      lcfg :: LedgerConfig i blk
      lcfg = configLedger $ getExtLedgerCfg cfg

      ledgerResult = applyChainTickLedgerResult lcfg slot ledger

instance TableStuff (LedgerState i blk) => TableStuff (ExtLedgerState i blk) where

  newtype LedgerTables (ExtLedgerState i blk) mk = ExtLedgerStateTables (LedgerTables (LedgerState i blk) mk)
    deriving (Generic)

  forgetLedgerStateTracking (ExtLedgerState lstate hstate) =
      ExtLedgerState (forgetLedgerStateTracking lstate) hstate

  forgetLedgerStateTables (ExtLedgerState lstate hstate) =
      ExtLedgerState (forgetLedgerStateTables lstate) hstate

  projectLedgerTables (ExtLedgerState lstate _) =
      ExtLedgerStateTables (projectLedgerTables lstate)
  withLedgerTables (ExtLedgerState lstate hstate) (ExtLedgerStateTables tables) =
      ExtLedgerState (lstate `withLedgerTables` tables) hstate

deriving instance ShowLedgerState (LedgerTables (LedgerState i blk)) => ShowLedgerState (LedgerTables (ExtLedgerState i blk))

instance (NoThunks (LedgerTables (LedgerState i blk) mk), Typeable mk) => NoThunks (LedgerTables (ExtLedgerState i blk) mk)

instance TickedTableStuff (LedgerState i blk) => TickedTableStuff (ExtLedgerState i blk) where
  forgetTickedLedgerStateTracking (TickedExtLedgerState lstate lview hstate) =
      TickedExtLedgerState (forgetTickedLedgerStateTracking lstate) lview hstate
  prependLedgerStateTracking
    (TickedExtLedgerState lstate1 _lview _hstate)
    (ExtLedgerState lstate2 hstate) =
      ExtLedgerState (prependLedgerStateTracking lstate1 lstate2) hstate
  trackingTablesToDiffs = undefined

instance ( LedgerSupportsProtocol i blk
         , Eq (ExtValidationError i blk)
         , NoThunks (ExtValidationError i blk)
         , Show (ExtValidationError i blk)
         , ShowLedgerState (ExtLedgerState i blk)
         , Typeable i
         , HeaderHash (LedgerState i blk)               ~ HeaderHash blk
         ) => ApplyBlock (ExtLedgerState i blk) blk where

  type Output (ExtLedgerState i blk) = Output (LedgerState i blk)

  applyBlockLedgerResult cfg blk TickedExtLedgerState{..} = do
    ledgerResult <-
        withExcept ExtValidationErrorLedger
      $ applyBlockLedgerResult
          (configLedger $ getExtLedgerCfg cfg)
          blk
          tickedLedgerState
    hdr <-
        withExcept ExtValidationErrorHeader
      $ validateHeader @blk
          (getExtLedgerCfg cfg)
          tickedLedgerView
          (getHeader blk)
          tickedHeaderState
    pure $ (\l -> ExtLedgerState l hdr) <$> castLedgerResult ledgerResult

  reapplyBlockLedgerResult cfg blk TickedExtLedgerState{..} =
      (\l -> ExtLedgerState l hdr) <$> castLedgerResult ledgerResult
    where
      ledgerResult =
        reapplyBlockLedgerResult
          (configLedger $ getExtLedgerCfg cfg)
          blk
          tickedLedgerState
      hdr      =
        revalidateHeader
          (getExtLedgerCfg cfg)
          tickedLedgerView
          (getHeader blk)
          tickedHeaderState

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

encodeExtLedgerState :: (LedgerState   i blk mk -> Encoding)
                     -> (ChainDepState (BlockProtocol blk) -> Encoding)
                     -> (AnnTip        blk    -> Encoding)
                     -> ExtLedgerState i blk mk -> Encoding
encodeExtLedgerState encodeLedgerState
                     encodeChainDepState
                     encodeAnnTip
                     ExtLedgerState{..} = mconcat [
      encodeLedgerState  ledgerState
    , encodeHeaderState' headerState
    ]
  where
    encodeHeaderState' = encodeHeaderState
                           encodeChainDepState
                           encodeAnnTip

decodeExtLedgerState :: (forall s. Decoder s (LedgerState    i blk mk))
                     -> (forall s. Decoder s (ChainDepState  (BlockProtocol blk)))
                     -> (forall s. Decoder s (AnnTip         blk))
                     -> (forall s. Decoder s (ExtLedgerState i blk mk))
decodeExtLedgerState decodeLedgerState
                     decodeChainDepState
                     decodeAnnTip = do
    ledgerState <- decodeLedgerState
    headerState <- decodeHeaderState'
    return ExtLedgerState{..}
  where
    decodeHeaderState' = decodeHeaderState
                           decodeChainDepState
                           decodeAnnTip

{-------------------------------------------------------------------------------
  Casts
-------------------------------------------------------------------------------}

castExtLedgerState
  :: ( Coercible (LedgerState i blk  mk)
                 (LedgerState i blk' mk)
     , Coercible (ChainDepState (BlockProtocol blk))
                 (ChainDepState (BlockProtocol blk'))
     , TipInfo blk ~ TipInfo blk'
     )
  => ExtLedgerState i blk mk -> ExtLedgerState i blk' mk
castExtLedgerState ExtLedgerState{..} = ExtLedgerState {
      ledgerState = coerce ledgerState
    , headerState = castHeaderState headerState
    }
