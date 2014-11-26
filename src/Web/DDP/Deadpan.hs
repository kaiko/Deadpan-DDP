{-|

Description: A collection of utilities to provide a way to create and run Deadpan apps.

A collection of utilities to provide a way to create and run Deadpan apps.

This should be the only Deadpan module imported by users intending to use Deadpan as a library
in order to write DDP applications.

-}


{-# LANGUAGE OverloadedStrings #-}

module Web.DDP.Deadpan
  ( module Web.DDP.Deadpan
  , module Web.DDP.Deadpan.DSL
  , module Web.DDP.Deadpan.Callbacks
  , module Control.Monad
  , getURI
  , Error
  , Params
  , liftIO
  )
  where

import Web.DDP.Deadpan.DSL
import Web.DDP.Deadpan.Websockets
import Web.DDP.Deadpan.Callbacks

import Data.Map
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class

-- | Run a DeadpanApp against a set of connection parameters
--
-- Automatically spawns a background thread to respond to server messages
-- using the callback set provided in the App State.
--
runClient :: AppState Callback -> Params -> DeadpanApp a -> IO a
runClient state params app = flip execURI params
                  $ \conn -> fmap fst $ runDeadpan (setup >> app) conn state

-- | Run a DeadpanApp against a set of connection parameters
--
--   Does not register any callbacks to handle server messages automatically.
--   This can be done with the `setup` function from "Web.DDP.Deadpan.DSL".
--
--   Useful for running one-shot command-set applications... Not much else.
--
runUnhookedClient :: AppState Callback -> Params -> DeadpanApp a -> IO a
runUnhookedClient state params app = flip execURI params
                          $ \conn -> fmap fst $ runDeadpan (connect >> app) conn state

-- | A client that registers no initial callbacks
--   Note: !!! This does not respond to ping,
--   so you better perform your actions quickly!

bareClient :: IO (AppState Callback)
bareClient = do
  values <- newTVarIO (ejobject [])
  return $ AppState (const $ return ()) Data.Map.empty values


-- | A client that only responds to pings so that it can stay alive

pingClient :: IO (AppState Callback)
pingClient = do
  values <- newTVarIO (ejobject [])
  return $ AppState (const $ return ()) (Data.Map.singleton "ping" pingCallback) values


-- | A client that logs all server sent messages, responds to pings

loggingClient :: IO (AppState Callback)
loggingClient = do
  values <- newTVarIO (ejobject [])
  return $ AppState (liftIO . print) (Data.Map.singleton "ping" pingCallback) values


-- | A client that responds to server collection messages.
--
--   TODO: NOT YET IMPLEMENTED

collectiveClient :: IO (AppState Callback)
collectiveClient = undefined
