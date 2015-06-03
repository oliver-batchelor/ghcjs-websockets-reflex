{-# LANGUAGE ScopedTypeVariables #-}

module JavaScript.WebSockets.Reflex.WebSocket 
  ( openConnection
  , holdConnection
  
  , receiveMessage
  , receive

  
  , receiveMessageOnce
  , receiveOnce
  
  , sendMessage      
  , send
  
  , SocketEvents(..)

  , closeConnection   
  , closeConnections
  
  , Connection
  , ConnClosing (..)
  , SocketMsg (..)
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
import Data.Maybe

import Data.Binary  

import Data.Foldable 
import Data.Traversable

import Control.Concurrent 

import qualified JavaScript.WebSockets as WS
import qualified JavaScript.WebSockets.Internal as WS


import JavaScript.WebSockets (ConnClosing, Connection, SocketMsg, WSReceivable, WSSendable)


-- Utility functions


-- Wrapper for performEventAsync where the function is called in another thread
forkEventAsync :: MonadWidget t m => Event t a -> (a -> (b -> IO ()) -> IO ()) -> m (Event t b)
forkEventAsync e f = performEventAsync $ ffor e $ \a cb -> liftIO $ do 
    void $ forkIO $ f a cb
    

    
performAsync ::  MonadWidget t m => Event t a -> (a -> IO b) -> m (Event t b)
performAsync e f = forkEventAsync e (\a cb -> f a >>= cb) 


-- Filter event stream with predicate and return ()
whenE_ :: (Reflex t) => (a -> Bool) -> Event t a -> Event t () 
whenE_ f = fmap (const ()) . ffilter f 

-- Split Either into two event streams
splitEither :: (Reflex t) => Event t (Either a b) -> (Event t a, Event t b)
splitEither e = (fmapMaybe (firstOf _Left) e, fmapMaybe (firstOf _Right) e)


-- Attach an event with it's previous value
history :: MonadWidget t m => Event t a -> m (Event t (Maybe a, a))
history event = do 
  value <- hold Nothing (fmap Just event)
  return $ attach value event
  

counter :: MonadWidget t m => Event t a -> m (Dynamic t Int)
counter event = foldDyn (+) 0 (fmap (const 1) event)


  
delay :: MonadWidget t m => Int -> Event t a -> m (Event t a)
delay n event = performAsync event (\a -> threadDelay n >> return a)


splitEvents :: (Reflex t) => Event t Int -> Event t (Int, a) -> Event t (Event t a)
splitEvents ids events = fmap (\i -> fmap snd $ ffilter ((==i) . fst) events) ids   


switchEvents :: (MonadWidget t m) => Event t Int -> Event t (Int, a) -> m (Event t a)
switchEvents ids events = switchPromptly never (splitEvents ids events)


iterateAsync :: (MonadWidget t m) => Event t a ->  (a -> IO (Maybe (a, b))) -> m (Event t b)  
iterateAsync trigger f = do
  
  rec
    count <- counter trigger 
    event <- performAsync (attachDyn count $ leftmost [trigger, fmap fst result])  f'
    result <- fmap (fmapMaybe id) $ switchEvents (updated count) event
    
  return (fmap snd result)
  
  where
    f' (i, a) = f a >>= \a' -> return (i, a')
    
repeatAsync :: (MonadWidget t m) => Event t a -> (a -> IO b) -> m (Event t b)  
repeatAsync trigger f = iterateAsync trigger f' 
  where
    f' a = f a >>= \b -> return $ Just (a, b)

  
tickOn :: (MonadWidget t m, Show a) => Int -> Event t a -> m (Event t a)
tickOn n trigger = repeatAsync trigger $ (\a -> threadDelay n  >> return a)
  

tick :: MonadWidget t m => Int -> m (Event t ())
tick n = getPostBuild >>= tickOn n


 
--Open connections for each url provided
openConnection :: MonadWidget t m => Event t Text -> m (Event t Connection)
openConnection request = forkEventAsync request  $ \url cb -> do
      WS.openConnection url >>= cb
      
      
holdConnection :: MonadWidget t m => Event t Text -> m (Dynamic t (Maybe Connection))
holdConnection request = do
  open <- openConnection request
  holdDyn Nothing (fmap Just open)
  
  
-- Periodically check the latest connection is still open
-- Event is triggered when a connection is lost
pollConnection :: MonadWidget t m => Int -> Event t Connection -> m (Event t WS.ConnClosing)
pollConnection microSeconds conn = do 
  poll <- tick microSeconds
  fmap (fmapMaybe id) $ performConnection checkClosed conn poll
  
  where
    checkClosed conn () = WS.connectionCloseReason conn
    
    
--Receieve messages using the latest connection     
receiveMessage :: (MonadWidget t m) => Event t Connection -> m (Event t (Maybe SocketMsg))
receiveMessage conn = iterateAsync (fmap Just conn) $ 

  -- On the first time through a Nothing message is returned (and Nothing connection), second time Nothing for the whole
  traverse $ \conn' -> do 
    msg  <- WS.receiveMessageMaybe conn'
    return (fmap (const conn') msg, msg)    
      


      
--Record type for labelling the various events returned
data SocketEvents t a = SocketEvents
  { socket_message      :: Event t a
  , socket_disconnected :: Event t ()
  , socket_decodeFail   :: Event t SocketMsg 
  }
      
      

            
--using the ghcjs-websockets WSReceivable class decode a socket message
unwrapReceivable :: forall t a. (Reflex t, WSReceivable a) => Event t (Maybe SocketMsg) -> SocketEvents t a
unwrapReceivable msgEvent = SocketEvents (snd dfm) disc (fst dfm) where
    disc = fmap (const ()) $ ffilter isNothing msgEvent
    
    dfm :: (Event t SocketMsg, Event t a)
    dfm = splitEither $ fmap WS.unwrapReceivable (fmapMaybe id msgEvent)

    
    
    
--Main receive API functions, returns SocketEvents record
receive  :: (MonadWidget t m, WSReceivable a) => Event t Connection -> m (SocketEvents t a)
receive = fmap unwrapReceivable . receiveMessage 


receiveMessageOnce  :: (MonadWidget t m) => Event t Connection -> m (Event t (Maybe SocketMsg))
receiveMessageOnce conn =  performAsync conn (WS.receiveMessageMaybe)

receiveOnce  :: (MonadWidget t m, WSReceivable a) => Event t Connection -> m (SocketEvents t a)
receiveOnce = fmap unwrapReceivable . receiveMessageOnce


performConnection :: (MonadWidget t m) => (Connection -> a -> IO b) ->  Event t Connection -> Event t a -> m (Event t b)
performConnection f conn event = do 
    latest <- holdDyn Nothing (fmap Just conn)
    e <- performEvent $ fmap perform (attachDyn latest event)
    return $ fmapMaybe id e  
      
    where  
      perform (mayConn, a) = liftIO $ for mayConn $ \conn -> f conn a


performConnection_ :: (MonadWidget t m) => (Connection -> a -> IO b) ->  Event t Connection -> Event t a -> m ()
performConnection_ f conn event = do 
    latest <- holdDyn Nothing (fmap Just conn)
    performEvent_ $ fmap perform (attachDyn latest event)
      
    where  
      perform (mayConn, a) = liftIO $ for_ mayConn $ \conn -> void $ f conn a
      
      
sendMessage :: (MonadWidget t m) =>  Event t Connection -> Event t SocketMsg -> m ()
sendMessage = performConnection_ WS.sendMessage


send :: (MonadWidget t m, WSSendable a) =>  Event t Connection  -> Event t a -> m ()
send = performConnection_ WS.send

closeConnection :: (MonadWidget t m) =>  Event t Connection -> Event t () -> m ()
closeConnection = performConnection_ (\conn () -> WS.closeConnection conn)
    

-- Close old connections, leaving only the most recently received connection open
closeConnections :: (MonadWidget t m) =>  Event t Connection ->  m ()   
closeConnections conn =  do
  prev <- hold Nothing (fmap Just conn)
  performEvent_ $ ffor (fmapMaybe id $ tag prev conn) $ liftIO . WS.closeConnection

 