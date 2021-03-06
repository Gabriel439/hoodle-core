{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.ContextMenu
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.ContextMenu where

-- from other packages
import           Control.Applicative
import           Control.Lens (view,set,(%~))
import           Control.Monad.State hiding (mapM_,forM_)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import           Data.Foldable (mapM_,forM_)
import qualified Data.IntMap as IM
import           Data.Monoid
import           Data.UUID.V4 
import qualified Data.Text.Encoding as TE
import           Graphics.Rendering.Cairo
import           Graphics.UI.Gtk hiding (get,set)
import           System.Directory 
import           System.FilePath
import           System.Process
-- from hoodle-platform
import           Control.Monad.Trans.Crtn.Event
import           Control.Monad.Trans.Crtn.Queue 
import           Data.Hoodle.BBox
import           Data.Hoodle.Generic
import           Data.Hoodle.Select
import           Data.Hoodle.Simple (SVG(..), Item(..), Link(..), defaultHoodle)
import           Graphics.Hoodle.Render
import           Graphics.Hoodle.Render.Item
import           Graphics.Hoodle.Render.Type
import           Graphics.Hoodle.Render.Type.HitTest
import           Text.Hoodle.Builder (builder)
-- from this package 
import           Hoodle.Accessor
import           Hoodle.Coroutine.Commit 
import           Hoodle.Coroutine.Dialog
import           Hoodle.Coroutine.Draw
import           Hoodle.Coroutine.File
import           Hoodle.Coroutine.Scroll
import           Hoodle.Coroutine.Select.Clipboard
import           Hoodle.Coroutine.Select.ManipulateImage
import           Hoodle.Coroutine.TextInput 
import           Hoodle.ModelAction.ContextMenu
import           Hoodle.ModelAction.Page 
import           Hoodle.ModelAction.Select
import           Hoodle.ModelAction.Select.Transform
import           Hoodle.Script.Hook
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Enum
import           Hoodle.Type.Event
import           Hoodle.Type.HoodleState
import           Hoodle.Type.PageArrangement 
import           Hoodle.Util
--
import Prelude hiding (mapM_) 


processContextMenu :: ContextMenuEvent -> MainCoroutine () 
processContextMenu (CMenuSaveSelectionAs ityp) = do 
  xst <- get
  forM_ (getSelectedItmsFromHoodleState xst) 
        (\hititms->  
           let ulbbox = (unUnion . mconcat . fmap (Union . Middle . getBBox)) hititms 
           in case ulbbox of 
                Middle bbox -> 
                  case ityp of 
                    TypSVG -> exportCurrentSelectionAsSVG hititms bbox
                    TypPDF -> exportCurrentSelectionAsPDF hititms bbox
                _ -> return () 
        )
processContextMenu CMenuCut = cutSelection
processContextMenu CMenuCopy = copySelection
processContextMenu CMenuDelete = deleteSelection
processContextMenu (CMenuCanvasView cid pnum _x _y) = do 
    xstate <- get 
    let cmap = view cvsInfoMap xstate 
    let mcinfobox = IM.lookup cid cmap 
    case mcinfobox of 
      Nothing -> liftIO $ putStrLn "error in processContextMenu"
      Just _cinfobox -> do 
        cinfobox' <- liftIO (setPage xstate pnum cid)
        put $ set cvsInfoMap (IM.adjust (const cinfobox') cid cmap) xstate 
        adjustScrollbarWithGeometryCvsId cid 
        invalidateAll 
processContextMenu (CMenuRotate dir imgbbx) = rotateImage dir imgbbx
processContextMenu CMenuAutosavePage = do 
    xst <- get 
    pg <- getCurrentPageCurr 
    mapM_ liftIO $ do 
      hset <- view hookSet xst
      customAutosavePage hset <*> pure pg 
processContextMenu (CMenuLinkConvert nlnk) = 
    either (const (return ())) action 
      . hoodleModeStateEither 
      . view hoodleModeState =<< get 
  where action thdl = do 
          xst <- get 
          case view gselSelected thdl of 
            Nothing -> return () 
            Just (n,tpg) -> do 
              let activelayer = rItmsInActiveLyr tpg
                  buf = view (glayers.selectedLayer.gbuffer) tpg
              ntpg <- case activelayer of 
                Left _ -> return tpg 
                Right (a :- _b :- as ) -> liftIO $ do
                  let nitm = ItemLink nlnk
                  nritm <- cnstrctRItem nitm
                  let alist' = (a :- Hitted [nritm] :- as )
                      layer' = GLayer buf . TEitherAlterHitted . Right $ alist'
                  return (set (glayers.selectedLayer) layer' tpg)
                Right _ -> error "processContextMenu: activelayer"
              nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg n
              commit . set hoodleModeState (SelectState nthdl)
                =<< (liftIO (updatePageAll (SelectState nthdl) xst))
              invalidateAll 
processContextMenu CMenuCreateALink = 
  fileChooser FileChooserActionOpen Nothing >>= mapM_ linkSelectionWithFile
processContextMenu CMenuAssocWithNewFile = do
  xst <- get 
  let msuggestedact = view hookSet xst >>= fileNameSuggestionHook 
  (msuggested :: Maybe String) <- maybe (return Nothing) (liftM Just . liftIO) msuggestedact 
  
  fileChooser FileChooserActionSave msuggested >>=   
    mapM_ (\fp -> do 
              b <- liftIO (doesFileExist fp)
              if b 
                then okMessageBox "The file already exist!"
                else do 
                  let action = mkIOaction $ \_ -> do                      
                        nhdl <- liftIO $ defaultHoodle   
                        (L.writeFile fp . builder) nhdl 
                        createProcess (proc "hoodle" [fp]) 
                        return (UsrEv ActionOrdered)
                  modify (tempQueue %~ enqueue action) 
                  waitSomeEvent (\x -> case x of ActionOrdered -> True ; _ -> False)
                  linkSelectionWithFile fp 
                  return ()
          ) 
processContextMenu (CMenuPangoConvert (x0,y0) txt) = textInput (x0,y0) txt
processContextMenu (CMenuLaTeXConvert (x0,y0) txt) = laTeXInput (x0,y0) txt
processContextMenu (CMenuLaTeXConvertNetwork (x0,y0) txt) = laTeXInputNetwork (x0,y0) txt 
processContextMenu (CMenuCropImage imgbbox) = cropImage imgbbox
processContextMenu CMenuCustom =  do
    either (const (return ())) action . hoodleModeStateEither . view hoodleModeState =<< get 
  where action thdl = do    
          xst <- get 
          forM_ (view gselSelected thdl) 
            (\(_,tpg) -> do 
              let hititms = (map rItem2Item . getSelectedItms) tpg  
              mapM_ liftIO $ do hset <- view hookSet xst    
                                customContextMenuHook hset <*> pure hititms)


--  | 
linkSelectionWithFile :: FilePath -> MainCoroutine ()  
linkSelectionWithFile fname = do
  liftM getSelectedItmsFromHoodleState get >>=  
    mapM_ (\hititms -> 
            let ulbbox = (unUnion . mconcat . fmap (Union . Middle . getBBox)) hititms 
            in case ulbbox of 
              Middle bbox -> do 
                svg <- liftIO $ makeSVGFromSelection hititms bbox
                uuid <- liftIO $ nextRandom
                let uuidbstr = B.pack (show uuid) 
                deleteSelection 
                linkInsert "simple" (uuidbstr,fname) fname (svg_render svg,bbox)  
              _ -> return () )

          
-- | 
exportCurrentSelectionAsSVG :: [RItem] -> BBox -> MainCoroutine () 
exportCurrentSelectionAsSVG hititms bbox@(BBox (ulx,uly) (lrx,lry)) = 
    fileChooser FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename =
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".svg" 
      then fileExtensionInvalid (".svg","export") 
           >> exportCurrentSelectionAsSVG hititms bbox
      else do      
        liftIO $ withSVGSurface filename (lrx-ulx) (lry-uly) $ \s -> renderWith s $ do 
          translate (-ulx) (-uly)
          mapM_ renderRItem  hititms


exportCurrentSelectionAsPDF :: [RItem] -> BBox -> MainCoroutine () 
exportCurrentSelectionAsPDF hititms bbox@(BBox (ulx,uly) (lrx,lry)) = 
    fileChooser FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename =
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".pdf" 
      then fileExtensionInvalid (".svg","export") 
           >> exportCurrentSelectionAsPDF hititms bbox
      else do      
        liftIO $ withPDFSurface filename (lrx-ulx) (lry-uly) $ \s -> renderWith s $ do 
          translate (-ulx) (-uly)
          mapM_ renderRItem  hititms


showContextMenu :: (PageNum,(Double,Double)) -> MainCoroutine () 
showContextMenu (pnum,(x,y)) = do 
    xstate <- get
    when (view (settings.doesUsePopUpMenu) xstate) $ do 
      let cids = IM.keys . view cvsInfoMap $ xstate
          cid = fst . view currentCanvas $ xstate 
          mselitms = do lst <- getSelectedItmsFromHoodleState xstate
                        if null lst then Nothing else Just lst 
      modify (tempQueue %~ enqueue (action xstate mselitms cid cids)) 
      >> waitSomeEvent (\e->case e of ContextMenuCreated -> True ; _ -> False) 
      >> return () 
  where 
    action xstate msitms cid cids  
      = Left . ActionOrder $ \evhandler -> do 
          menu <- menuNew 
          menuSetTitle menu "MyMenu"
          case msitms of 
            Nothing -> return ()
            Just sitms -> do 
              menuitem1 <- menuItemNewWithLabel "Make SVG"
              menuitem2 <- menuItemNewWithLabel "Make PDF"
              menuitem3 <- menuItemNewWithLabel "Cut"
              menuitem4 <- menuItemNewWithLabel "Copy"
              menuitem5 <- menuItemNewWithLabel "Delete"
              menuitem6 <- menuItemNewWithLabel "New File Linked Here"
              menuitem1 `on` menuItemActivate $   
                evhandler (UsrEv (GotContextMenuSignal (CMenuSaveSelectionAs TypSVG)))
              menuitem2 `on` menuItemActivate $ 
                evhandler (UsrEv (GotContextMenuSignal (CMenuSaveSelectionAs TypPDF)))
              menuitem3 `on` menuItemActivate $ 
                evhandler (UsrEv (GotContextMenuSignal (CMenuCut)))
              menuitem4 `on` menuItemActivate $    
                evhandler (UsrEv (GotContextMenuSignal (CMenuCopy)))
              menuitem5 `on` menuItemActivate $    
                evhandler (UsrEv (GotContextMenuSignal (CMenuDelete)))
              menuitem6 `on` menuItemActivate $ 
                evhandler (UsrEv (GotContextMenuSignal (CMenuAssocWithNewFile)))
              menuAttach menu menuitem1 0 1 1 2 
              menuAttach menu menuitem2 0 1 2 3
              menuAttach menu menuitem3 1 2 0 1                     
              menuAttach menu menuitem4 1 2 1 2                     
              menuAttach menu menuitem5 1 2 2 3    
              menuAttach menu menuitem6 1 2 3 4 
              mapM_ (\mi -> menuAttach menu mi 1 2 5 6) =<< menuCreateALink evhandler sitms 
              case sitms of 
                sitm : [] -> do 
                  case sitm of 
                    RItemLink lnkbbx _msfc -> do 
                      let lnk = bbxed_content lnkbbx
                      forM_ ((urlParse . B.unpack . link_location) lnk)
                            (\urlpath -> do milnk <- menuOpenALink urlpath
                                            menuAttach menu milnk 0 1 3 4 )
                      case lnk of 
                        Link _i _typ _lstr _txt _cmd _rdr _pos _dim ->  
                          convertLinkFromSimpleToDocID lnk >>=  
                            mapM_ (\link -> do 
                              let LinkDocID _ uuid _ _ _ _ _ _ = link 
                              menuitemcvt <- menuItemNewWithLabel ("Convert Link With ID" ++ show uuid) 
                              menuitemcvt `on` menuItemActivate $ do
                                evhandler (UsrEv (GotContextMenuSignal (CMenuLinkConvert link)))
                              menuAttach menu menuitemcvt 0 1 4 5 
                            ) 
                        LinkDocID i lid file txt cmd rdr pos dim -> do 
                          case (lookupPathFromId =<< view hookSet xstate) of
                            Nothing -> return () 
                            Just f -> do 
                              rp <- f (B.unpack lid)
                              case rp of 
                                Nothing -> return ()
                                Just file' -> 
                                  if (B.unpack file) == file' 
                                  then return ()
                                    else do 
                                      let link = LinkDocID i lid (B.pack file') txt cmd rdr pos dim
                                      menuitemcvt <- menuItemNewWithLabel ("Correct Path to " ++ show file') 
                                      menuitemcvt `on` menuItemActivate $ 
                                        evhandler (UsrEv (GotContextMenuSignal (CMenuLinkConvert link)))
                                      menuAttach menu menuitemcvt 0 1 4 5 
                    RItemSVG svgbbx _msfc -> do
                      let svg = bbxed_content svgbbx
                          BBox (x0,y0) _ = getBBox svgbbx
                      forM_ ((,) <$> svg_text svg <*> svg_command svg) $ \(btxt,cmd) -> do
                        let txt = TE.decodeUtf8 btxt
                        case cmd of 
                          "pango" -> do 
                            menuitemedt <- menuItemNewWithLabel ("Edit Text") 
                            menuitemedt `on` menuItemActivate $ do 
                              evhandler (UsrEv (GotContextMenuSignal (CMenuPangoConvert (x0,y0) txt)))
                            menuAttach menu menuitemedt 0 1 4 5
                            return ()
                          "latex" -> do 
                            menuitemedt <- menuItemNewWithLabel ("Edit LaTeX")
                            menuitemedt `on` menuItemActivate $ do
                              evhandler (UsrEv (GotContextMenuSignal (CMenuLaTeXConvert (x0,y0) txt)))
                            menuAttach menu menuitemedt 0 1 4 5 
                            --
                            menuitemnet <- menuItemNewWithLabel ("Edit LaTeX Network")
                            menuitemnet `on` menuItemActivate $ do
                              evhandler (UsrEv (GotContextMenuSignal (CMenuLaTeXConvertNetwork (x0,y0) txt)))
                            menuAttach menu menuitemnet 0 1 5 6
                            return ()
                          _ -> return ()
                    RItemImage imgbbx _msfc -> do
                      let img = bbxed_content imgbbx
                          BBox (x0,y0) _ = getBBox imgbbx
                      menuitemcrop <- menuItemNewWithLabel ("Crop Image") 
                      menuitemcrop `on` menuItemActivate $ do 
                        (evhandler . UsrEv . GotContextMenuSignal . CMenuCropImage) imgbbx
                      menuitemrotcw <- menuItemNewWithLabel ("Rotate Image CW") 
                      menuitemrotcw `on` menuItemActivate $ do 
                        (evhandler . UsrEv . GotContextMenuSignal) (CMenuRotate CW imgbbx)
                      menuitemrotccw <- menuItemNewWithLabel ("Rotate Image CCW") 
                      menuitemrotccw `on` menuItemActivate $ do 
                        (evhandler . UsrEv . GotContextMenuSignal) (CMenuRotate CCW imgbbx)
                      -- 
                      menuAttach menu menuitemcrop 0 1 4 5
                      menuAttach menu menuitemrotcw 0 1 5 6
                      menuAttach menu menuitemrotccw 0 1 6 7
                      -- 
                      return ()
                    _ -> return ()

                _ -> return () 
          case (customContextMenuTitle =<< view hookSet xstate) of 
            Nothing -> return () 
            Just ttl -> do 
              custommenu <- menuItemNewWithLabel ttl  
              custommenu `on` menuItemActivate $ 
                evhandler (UsrEv (GotContextMenuSignal (CMenuCustom)))
              menuAttach menu custommenu 0 1 0 1 

          menuitem8 <- menuItemNewWithLabel "Autosave This Page Image"
          menuitem8 `on` menuItemActivate $ 
            evhandler (UsrEv (GotContextMenuSignal (CMenuAutosavePage)))
          menuAttach menu menuitem8 1 2 4 5 

          runStateT (mapM_ (makeMenu evhandler menu cid) cids) 0 
          widgetShowAll menu 
          menuPopup menu Nothing 
          return (UsrEv ContextMenuCreated)

    makeMenu evhdlr mn currcid cid = when (currcid /= cid) $ do 
      n <- get
      mi <- liftIO $ menuItemNewWithLabel ("Show here in cvs" ++ show cid)
      liftIO $ mi `on` menuItemActivate $ 
        evhdlr (UsrEv (GotContextMenuSignal (CMenuCanvasView cid pnum x y)))
      liftIO $ menuAttach mn mi 2 3 n (n+1) 
      put (n+1) 
    
