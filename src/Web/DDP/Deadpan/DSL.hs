{-|

Description: An EDSL designed to make writing deadpan applications easy!

An EDSL designed to make writing deadpan applications easy!

This DSL is a simple decoration of some application specific functions
arround a ReaderT monad instance.

A core cabal of functions are exported from this module which are then put to use
in web.ddp.deadpan to create an expressive dsl for creating ddp applications.

The main functions exported are...

TODO: Ensure these are up to date...

* rundeadpan
* sethandler
* deletehandler
* setdefaulthandler
* senddata
* sendmessage

these allow you to...

* run a deadpan application with some initial set of callbacks
* set new values for response handlers
* delete existing response handlers
* set a handler to act when no existing handler matches the incomming message
* send an ejsonvalue to the server (low-level)
* send messages to be interpreted as rpc calls

... respectively.

There is also a `control.lens.lens` `collections` provided into a single ejsonvalue.

This can be used to...

* Retrieve any current collection data
* Set collection data manually
* Perform actions on collection data in callbacks

-}

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Web.DDP.Deadpan.DSL
  ( module Web.DDP.Deadpan.DSL
  , module Data.EJson
  , Text
  , pack
  )
  where

-- External Imports

import Control.Concurrent.STM
import Control.Concurrent
import Control.Applicative
import Network.WebSockets
import Control.Monad.Reader
import Control.Lens
import Data.Monoid
import Data.Text hiding (reverse, map)
import Data.UUID.V4     (nextRandom)
import Data.UUID        (toString)

-- Internal Imports

import Web.DDP.Deadpan.Comms
import Data.EJson


-- Let's do this!

-- | The LookupItem data-type is used to store a set of callbacks.
--
--   _ident is a reference to the callback, not the expected message id.
--
data LookupItem a = LI { _ident :: Text, _body :: a }

makeLenses ''LookupItem

type Lookup a = [ LookupItem a ]

data AppState cb = AppState
  { _callbackSet :: Lookup cb                      -- ^ Callbacks to match against by message
  , _collections :: EJsonValue                     -- ^ Shared data Expected to be an EJObject
  , _connection  :: Network.WebSockets.Connection  -- ^ Network connection to server
  }

makeLenses ''AppState

type Callback = EJsonValue -> DeadpanApp () -- TODO: Allow any return type from callback

newtype DeadpanApp a = DeadpanApp
  { _deadpanApp :: ReaderT
                     (TVar (AppState Callback)) -- Reader
                     IO                         -- Parent Monad
                     a                          -- Result
  }

instance Monad DeadpanApp where
  return  = DeadpanApp . return
  s >>= f = DeadpanApp $ _deadpanApp s >>= _deadpanApp . f

instance Functor DeadpanApp where
  fmap f (DeadpanApp m) = DeadpanApp $ fmap f m

instance Applicative DeadpanApp where
  pure = DeadpanApp . pure
  (DeadpanApp f) <*> (DeadpanApp m) = DeadpanApp (f <*> m)

instance MonadIO DeadpanApp where
  liftIO i = DeadpanApp $ liftIO i

makeLenses ''DeadpanApp

data Version = Vpre1 | Vpre2 | V1 deriving (Eq, Ord, Enum, Bounded, Read, Show)

version2string :: Version -> EJsonValue
version2string Vpre1 = ejstring "pre1"
version2string Vpre2 = ejstring "pre2"
version2string V1    = ejstring "1"

reverseVersions :: [EJsonValue]
reverseVersions = map version2string $ reverse [minBound ..]

-- | The order of these args match that of runReaderT
--
runDeadpan :: DeadpanApp a
           -> TVar (AppState Callback)
           -> IO a
runDeadpan app appState = runReaderT (_deadpanApp app) appState

-- IDs
--
newID :: DeadpanApp Text
newID = do guid <- liftIO nextRandom
           let str  = toString guid
               text = pack str
           return text

-- Handlers

addHandler :: LookupItem Callback -> DeadpanApp ()
addHandler i = modifyAppState foo
  where foo x = x &~ callbackSet %= (i:)

setHandler :: Text -> Callback -> DeadpanApp Text
setHandler guid cb = addHandler (LI guid cb) >> return guid

onMatchId :: Text -> Callback -> Callback
onMatchId guid cb e = when (matches (makeId guid) e) (cb e)

setIdHandler :: Text -> Callback -> DeadpanApp Text
setIdHandler myid cb = setHandler myid (onMatchId myid cb)

onMatchMsg :: Text -> Callback -> Callback
onMatchMsg t cb e = when (matches (makeMsg t) e) (cb e)

setMsgHandler :: Text -> Callback -> DeadpanApp Text
setMsgHandler msg cb = newID >>= flip setHandler (onMatchMsg msg cb)

setCatchAllHandler :: Callback -> DeadpanApp Text
setCatchAllHandler cb = newID >>= flip setHandler cb

deleteHandlerID :: Text -> DeadpanApp ()
deleteHandlerID k = modifyAppState $
                    over callbackSet (Prelude.filter ((/= k) . _ident))

modifyAppState :: (AppState Callback -> AppState Callback) -> DeadpanApp ()
modifyAppState f = DeadpanApp
  $ do st <- ask
       liftIO $ atomically $ do s <- readTVar st
                                writeTVar st (f s)

getAppState :: DeadpanApp (AppState Callback)
getAppState = DeadpanApp $ ask >>= liftIO . atomically . readTVar

-- | A low-level function intended to be able to send any arbitrary data to the server.
--   Given that all messages to the server are intended to fit the "message" format,
--   You should probably use `sendMessage` instead.
--   TODO: Decide if this should perform the request in a seperate thread...
sendData :: EJsonValue -> DeadpanApp ()
sendData v = getAppState >>= liftIO . flip sendEJ v . _connection

-- | Send a particular type of message (indicated by the key) to the server.
--   This should be the primary means of [client -> server] communication by
--   a client application.
sendMessage :: Text -> EJsonValue -> DeadpanApp ()
sendMessage key m = sendData messageData
  where
  messageData = makeMsg key `mappend` m

connectVersion :: Version -> DeadpanApp ()
connectVersion v = sendMessage "connect" $ ejobject [ ("version", version2string v)
                                                    , ("support", ejarray $ reverseVersions) ]

connect :: DeadpanApp ()
connect = sendMessage "connect" $ ejobject [ ("version", version2string V1)
                                           , ("support", ejarray $ reverseVersions) ]

-- | Provides a way to fork a background thread running the app provided
fork :: DeadpanApp a -> DeadpanApp ThreadId
fork app = do
  st <- DeadpanApp ask
  liftIO $ forkIO $ void $ runDeadpan app st

fetchMessages :: DeadpanApp ()
fetchMessages = void      $
                 fork     $
                  forever $ do message <- getServerMessage
                               as      <- getAppState
                               fork $ respondToMessage (_callbackSet as) message

getServerMessage :: DeadpanApp (Maybe EJsonValue)
getServerMessage = getAppState >>= liftIO . getEJ . _connection

-- | Loop through all callbacks
--
--   Each callback is responsible for discarding messages
--   that it doesn't care about...
--
respondToMessage :: Lookup Callback -> Maybe EJsonValue -> DeadpanApp ()
respondToMessage _     Nothing        = return ()
respondToMessage cbSet (Just message) = mapM_ (flip _body message) cbSet
