{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE EmptyCase                #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE InstanceSigs             #-}
{-# LANGUAGE KindSignatures           #-}
{-# LANGUAGE PolyKinds                #-}
{-# LANGUAGE QuantifiedConstraints    #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE StandaloneDeriving       #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE UndecidableInstances     #-}

module Ouroboros.Network.Protocol.Trans.Hello.Type where

import           Data.Kind (Type)
import           Data.Singletons
import           Data.Void (Void)

import           Network.TypedProtocol.Core
import           Ouroboros.Network.Util.ShowProxy


-- | The 'Hello' protocol transformer reverses the initial agency of the protocol,
-- from one in which the server has the initial agency to one in which the client
-- has the initial agency.
--
-- It extends the underlying protocol with an initial extra 'MsgHello' message,
-- which reverses the agency between the two peers.
--
data Hello ps (stIdle :: ps) where
    -- | 'StHello' state is the initial state of the 'Hello' protocol.
    --
    StHello  :: Hello ps stIdle

    -- | 'StTalk' embeds states of the inner protocol.
    --
    StTalk :: ps -> Hello ps stIdle

instance ( ShowProxy ps
         , ShowProxy stIdle
         )
      => ShowProxy (Hello ps (stIdle :: ps)) where
    showProxy _ = "Hello "
               ++ showProxy (Proxy :: Proxy ps)
               ++ " "
               ++ showProxy (Proxy :: Proxy stIdle)

-- | Singletons for 'Hello' protocol state types.
--
type SingHello :: Hello ps stIdle -> Type
data SingHello k where
    SingHello :: SingHello StHello
    SingTalk  :: Sing stInner
              -> SingHello (StTalk stInner)

instance Show (SingHello StHello) where
    show SingHello = "SingHello"
instance Show (Sing stInner)
      => Show (SingHello (StTalk stInner)) where
    show (SingTalk inner) = "SingTalk " ++ show inner

type instance Sing = SingHello
instance SingI StHello          where sing = SingHello
instance SingI stInner
      => SingI (StTalk stInner) where sing = SingTalk sing

instance Protocol ps => Protocol (Hello ps stIdle) where
    data Message (Hello ps stIdle) from to where
      -- | Client side hello message.
      --
      MsgHello :: Message (Hello ps stIdle) StHello (StTalk stIdle)

      -- | After initial hello message one proceeds with the wrapped protocol
      -- 'ps'.
      --
      MsgTalk :: Message ps stInner stInner'
                 -> Message (Hello ps stIdle) (StTalk stInner) (StTalk stInner')


    -- | Either initial 'StHello' state or 'ps' protocol states, which have client
    -- agency or an inner protocol state.  This is embedding of the 'ps' client
    -- states into client states of the wrapper.
    --
    type StateAgency StHello          = ClientAgency
    type StateAgency (StTalk stInner) = StateAgency stInner


instance (forall (from' :: ps) (to' :: ps). Show (Message ps from' to'))
      => Show (Message (Hello ps stIdle) from to) where
    show MsgHello         = "MsgHello"
    show (MsgTalk msg) = "MsgTalk " ++ show msg
