{-# LANGUAGE FlexibleContexts #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.Callback 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.Callback where

-- from other packages
import Control.Applicative
import Control.Concurrent 
import Control.Monad.Error
import Control.Monad.State
import Control.Monad.Trans.Free
-- import Data.IORef
-- from hoodle-platform
import Control.Monad.Trans.Crtn 
import Control.Monad.Trans.Crtn.Driver
import Control.Monad.Trans.Crtn.EventHandler 
import Control.Monad.Trans.Crtn.Object
import Control.Monad.Trans.Crtn.Logger
-- from this package 
import Hoodle.Type.Coroutine
import Hoodle.Type.Event 

-- | common event handler
bouncecallback :: EventVar -> MyEvent -> IO () 
bouncecallback = eventHandler
  
{-  evar ev = do 
    mnext <- takeMVar evar
    case mnext of 
      Nothing -> return () 
      Just drv -> do                
        eaction drv >>= either (\err -> scribe (show err) >> return drv) return >>= putMVar evar . Just  
          where eaction = evalStateT $ runErrorT $ fire ev >> lift get >>= return
-}        
        
        {-        enext' <- runErrorT (fst <$> (next <==| dispatch ev)) -- next
        either (error "end? in bouncecallback") (putMVar evar.Just) enext' 
-}        
        
        
{-        next' <- do 
          x <- runFreeT (next ev)
          case x of 
            Pure () -> error "end? in boundcallback" -- partial
            Free (Awt next') -> return next' 
        putMVar evar (Just next')
-}