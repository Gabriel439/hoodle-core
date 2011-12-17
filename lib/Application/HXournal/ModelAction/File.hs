{-# LANGUAGE OverloadedStrings #-}

module Application.HXournal.ModelAction.File where

import Application.HXournal.Type.XournalState
import Application.HXournal.Type.Canvas
import Application.HXournal.ModelAction.Page
import qualified Text.Xournal.Parse as P
import qualified Data.IntMap as M
import Control.Category
import Data.Label
import Prelude hiding ((.),id)

import Data.Xournal.Map
import Data.Xournal.Simple
import Data.Xournal.Generic
import Graphics.Xournal.Render.Generic
import Graphics.Xournal.Render.BBoxMapPDF
import Graphics.Xournal.Render.PDFBackground

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C

import qualified Graphics.UI.Gtk.Poppler.Document as Poppler
import qualified Graphics.UI.Gtk.Poppler.Page as PopplerPage

-- | get file content from xournal file and update xournal state 

getFileContent :: Maybe FilePath 
               -> HXournalState 
               -> IO HXournalState 
getFileContent (Just fname) xstate = do 
    xojcontent <- P.read_xournal fname 
    nxstate <- constructNewHXournalStateFromXournal xojcontent xstate 
    return $ set currFileName (Just fname) nxstate 

{-    let currcid = get currentCanvas xstate 
        cmap = get canvasInfoMap xstate 
    xoj <- mkTXournalBBoxMapPDF xojcontent 
    let Dim width height = case M.lookup 0 (gpages xoj) of    
                             Nothing -> error "no first page in getFileContent" 
                             Just p -> gdimension p 
        startingxojstate = ViewAppendState xoj
        -- cids = M.keys cmap 
        -- update x _cinfo = 
    let changefunc c = 
          setPage startingxojstate 0 
          . set viewInfo (ViewInfo OnePage Original (0,0) (width,height))
          . set currentPageNum 0 
          $ c 
          -- in  M.adjust changefunc x cmap  
        cmap' = fmap changefunc cmap
        -- foldr update cmap cids   
    let newxstate = set xournalstate startingxojstate
                    . set currFileName (Just fname)
                    . set canvasInfoMap cmap'
                    . set currentCanvas currcid 
                    $ xstate 
    return newxstate -} 
getFileContent Nothing xstate = do   
    newxoj <- mkTXournalBBoxMapPDF defaultXournal 
    let newxojstate = ViewAppendState newxoj 
        xstate' = set currFileName Nothing 
                  . set xournalstate newxojstate
                  $ xstate 
        cmap = get canvasInfoMap xstate'
    let Dim w h = page_dim . (!! 0) .  xoj_pages $ defaultXournal
        ciupdt = setPage newxojstate 0                       
                 . set viewInfo (ViewInfo OnePage Original (0,0) (w,h))
                 . set currentPageNum 0 
        cmap' = M.map ciupdt cmap
    return (set canvasInfoMap cmap' xstate')

constructNewHXournalStateFromXournal :: Xournal -> HXournalState -> IO HXournalState 
constructNewHXournalStateFromXournal xoj xstate = do 
    let currcid = get currentCanvas xstate 
        cmap = get canvasInfoMap xstate 
    xoj <- mkTXournalBBoxMapPDF xoj
    let Dim width height = case M.lookup 0 (gpages xoj) of    
                             Nothing -> error "no first page in getFileContent" 
                             Just p -> gdimension p 
        startingxojstate = ViewAppendState xoj
    let changefunc c = 
          setPage startingxojstate 0 
          . set viewInfo (ViewInfo OnePage Original (0,0) (width,height))
          . set currentPageNum 0 
          $ c 
        cmap' = fmap changefunc cmap
    return $ set xournalstate startingxojstate
             . set canvasInfoMap cmap'
             . set currentCanvas currcid 
             $ xstate



makeNewXojWithPDF :: FilePath -> IO (Maybe Xournal)
makeNewXojWithPDF fp = do 
  let fname = C.pack fp 
  mdoc <- popplerGetDocFromFile fname
  case mdoc of 
    Nothing -> do 
      putStrLn $ "no such file " ++ fp 
      return Nothing 
    Just doc -> do 
      n <- Poppler.documentGetNPages doc 
      pg <- Poppler.documentGetPage doc 0 
      (w,h) <- PopplerPage.pageGetSize pg
      let dim = Dim w h 
          xoj = set s_title fname 
                . set s_pages (map (createPage dim fname) [1..n]) 
                $ emptyXournal
      putStrLn $ "total num of pages " ++ show n 
      putStrLn $ "size = " ++ show (w,h)
      return (Just xoj)
      
      
createPage :: Dimension -> B.ByteString -> Int -> Page
createPage dim fn n 
  | n == 1 = let bkg = BackgroundPdf "pdf" (Just "absolute") (Just fn ) n 
             in  Page dim bkg [emptyLayer]
  | otherwise = let bkg = BackgroundPdf "pdf" Nothing Nothing n 
                in Page dim bkg [emptyLayer]