{-# LANGUAGE ScopedTypeVariables, TypeFamilies #-}

module JavaScript.WebSockets.Reflex.WebSocket 
  ( openConnection
  , checkDisconnected
  
  , receiveMessage
  , receiveMessages
  
  , disconnected
  , unwrapEvents
  , unwrapWith

  
  , decodeMessage
  , textMessage
      
  , WS.unwrapReceivable

  , sendMessage
  , sendMessage2 
  , send
  
  , switchEvents
  , iterateEvent

  , SocketMsg(..)
  , WSReceivable
  , WSSendable
  
  , Connection
  , ConnClosing
  
  )
  where


import Reflex
import Reflex.Dom

import Reflex.Dom.Class
import Reflex.Host.Class

import Control.Monad
import Control.Monad.IO.Class
import Control.Lens

import Control.Concurrent

import Data.Text (Text)
import Data.ByteString.Lazy  (ByteString, fromStrict, toStrict)


import Data.Maybe
import Data.Tuple (swap)

import Data.Binary  

import Data.Foldable 
import Data.Traversable
import Data.Functor

import Control.Concurrent 

import qualified JavaScript.WebSockets as WS
import qualified JavaScript.WebSockets.Internal as WS


import JavaScript.WebSockets (ConnClosing, Connection, SocketMsg, WSReceivable, WSSendable)




-- Utility functions
  
forkEventAsync' :: MonadWidget t m =>  (a -> (b -> IO ()) -> IO ()) ->  Event t a -> m (Event t b)
forkEventAsync' f e = performEventAsync $ ffor e $ \a cb -> liftIO $ do 
    void $ forkIO $ f a cb
    

forkEventAsync ::  MonadWidget t m => (a -> IO b) -> Event t a ->  m (Event t b)
forkEventAsync f = forkEventAsync' (\a cb -> f a >>= cb) 

generateAsync ::  (MonadWidget t m) => (a -> IO b) -> a -> m (Event t b)
generateAsync f a = once a >>= forkEventAsync f

generate ::  (MonadWidget t m) => (a -> IO b) -> a -> m (Event t b)
generate f a = do
  e <- once a 
  performEvent $ fmap (liftIO . f) e


-- Split Either into two event streams
splitEither :: (Reflex t) => Event t (Either a b) -> (Event t a, Event t b)
splitEither e = (fmapMaybe (firstOf _Left) e, fmapMaybe (firstOf _Right) e)


catMaybesE :: (Reflex t) => Event t (Maybe a) -> Event t a
catMaybesE = fmapMaybe id

tagConst :: (Reflex t) => a -> Event t b -> Event t a
tagConst a = fmap (const a) 


unTag :: (Reflex t) => Event t a -> Event t ()
unTag = fmap (const ())

once :: (MonadWidget t m) => a -> m (Event t a) 
once a = do
  postBuild <- getPostBuild    
  return (fmap (const a) postBuild) 



splitMaybe :: (Reflex t) => Event t (Maybe a) -> (Event t (), Event t a)
splitMaybe e = (unTag $ ffilter isNothing e, catMaybesE e)
  
  
-- |Given a function f which generates an event stream given an 'a',
-- |upgrade it to a function which takes an event stream of 'a' and switches
-- |to a the event stream for each input 'a'.
switchEvents :: MonadWidget t m => (a -> m (Event t b)) -> Event t a -> m (Event t b)
switchEvents f e = fmap switchPromptlyDyn $ widgetHold (return never) (f <$> e) 
 

-- |Iterate an event generator, every time an event is recieved
-- |feed the input back to itself.
-- |Note: the input generator must be delayed, e.g. the result of a performEventAsync
iterateEvent :: MonadWidget t m => (Event t a -> m (Event t a)) -> Event t a -> m (Event t a)
iterateEvent f e = do
  rec
    next <- f $ leftmost [e, next]
  return next     

        
delay :: MonadWidget t m => Int -> Event t a -> m (Event t a)
delay ms = forkEventAsync (\a -> threadDelay ms >> return a) 


tick :: MonadWidget t m => Int -> m (Event t ())
tick ms = getPostBuild >>= iterateEvent (delay ms)
        
 
-- |Open a connection
-- |Can be upgraded to operate on an event of Urls
-- |switchEvents openConnection :: Event Text -> m (Event t Connection)
openConnection :: MonadWidget t m => Text -> m (Event t Connection)
openConnection = generate WS.openConnection
      
      
      
-- |Receieve one message for each incoming Connection event.      
receiveMessage :: MonadWidget t m => Event t Connection ->  m (Event t (Maybe SocketMsg))
receiveMessage = forkEventAsync WS.receiveMessageMaybe


-- |Repeatedly receive messages from a given Connection.
-- |Can be upgraded to take an Event of Connections and switch to the new Connection when received.
-- |switchEvents receiveMessages :: Event Connection -> m (Event t (Maybe SocketMsg))
receiveMessages :: MonadWidget t m => Connection -> m (Event t (Maybe SocketMsg))
receiveMessages conn = do
--   rec
--     initial <- once conn
--     e <- receiveMessage $ leftmost [const conn <$> catMaybesE e, initial]
  return never

-- |Disconnected event from message event.
disconnected :: Reflex t => Event t (Maybe SocketMsg) -> Event t ()
disconnected = unTag . ffilter isNothing


-- |Unwrap an event from message event, using the ghcjs_websockets WSReceivable
-- |Has instances for all Binary a and Text
-- |returns two events, successfully unwrapped messages and messages which could not be decoded
unwrapEvents :: (WSReceivable a, Reflex t) =>  Event t (Maybe SocketMsg) -> (Event t a, Event t SocketMsg)
unwrapEvents  = swap . splitEither . fmap WS.unwrapReceivable . catMaybesE


unwrapMaybe :: (SocketMsg -> Maybe a) -> SocketMsg -> Either SocketMsg a
unwrapMaybe f m = case f m of
    Nothing   -> Left m
    Just   a  -> Right a


unwrapWith :: Reflex t => (SocketMsg -> Maybe a) ->  Event t (Maybe SocketMsg) -> (Event t a, Event t SocketMsg)
unwrapWith f = swap . splitEither . fmap (unwrapMaybe f) . catMaybesE

    
-- |Decode a binary SocketMsg using the Binary class
-- |returns two events, successfully decoded messages and messages which could not be decoded  
decodeMessage :: (Binary a, Reflex t) => Event t (Maybe SocketMsg) -> (Event t a, Event t SocketMsg)  
decodeMessage = unwrapEvents


-- |Unwrap a text SocketMsg
-- |returns two events, messages which are Text, and messages are binary  
-- | e.g.  fst . textMessage <$> receiveMessages conn :: m (Event t Text) 
-- | 
textMessage :: (Reflex t) => Event t (Maybe SocketMsg) -> (Event t Text, Event t SocketMsg)  
textMessage = unwrapEvents


-- |Periodically check the latest connection is still open,
-- |the event is triggered when a connection is lost.
checkDisconnected :: MonadWidget t m => Int -> Connection -> m (Event t WS.ConnClosing)
checkDisconnected microSeconds conn = do 
  poll <- tick microSeconds
  e <- performEvent $ ffor poll (const $ liftIO $ WS.connectionCloseReason conn)
  return (catMaybesE e)
  

-- | Send messages to a connection.
-- | arguments are ordered this way so that one might use switchEvents e.g.
-- | switchEvents (sendMessage msg) :: Event Connection -> m (Event t ())  
-- | returns an Event for the success/failure of sending.
sendMessage :: (MonadWidget t m) =>  Event t SocketMsg -> Connection -> m (Event t Bool)
sendMessage msg conn = performEvent $ ffor msg $ liftIO . WS.sendMessage conn
  

-- | Send messages to a connection using WSSendable.
-- | instances for all Binary a and Text  
send :: (WSSendable a, MonadWidget t m) =>  Event t a -> Connection -> m (Event t Bool)
send a conn = performEvent $ ffor a $ liftIO . WS.send conn


 