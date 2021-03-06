{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.Default 
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : GPL-3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.Default where

import           Control.Applicative ((<$>))
import           Control.Category
import           Control.Concurrent 
import           Control.Lens (_1,over,view,set,at,(.~),(%~))
import           Control.Monad.Reader
import           Control.Monad.State 
import qualified Data.ByteString.Char8 as B
import qualified Data.IntMap as M
import           Data.IORef 
import           Data.Maybe
import           Data.Monoid ((<>))
import           Data.Time.Clock
import           Graphics.UI.Gtk hiding (get,set)
import           System.Process 
-- from hoodle-platform
import           Control.Monad.Trans.Crtn.Driver
import           Control.Monad.Trans.Crtn.Object
import           Control.Monad.Trans.Crtn.Logger.Simple
import           Control.Monad.Trans.Crtn.Queue 
import           Data.Hoodle.Select
import           Data.Hoodle.Simple (Dimension(..))
import           Data.Hoodle.Generic
import           Graphics.Hoodle.Render.Type.Background
-- from this package
import           Hoodle.Accessor
import           Hoodle.Coroutine.Callback
import           Hoodle.Coroutine.Commit
import           Hoodle.Coroutine.ContextMenu
import           Hoodle.Coroutine.Draw
import           Hoodle.Coroutine.Eraser
import           Hoodle.Coroutine.File
import           Hoodle.Coroutine.Highlighter
import           Hoodle.Coroutine.Layer 
import           Hoodle.Coroutine.Link
import           Hoodle.Coroutine.Page
import           Hoodle.Coroutine.Pen
import           Hoodle.Coroutine.Scroll
import           Hoodle.Coroutine.Select
import           Hoodle.Coroutine.Select.Clipboard
import           Hoodle.Coroutine.TextInput 
import           Hoodle.Coroutine.Mode
import           Hoodle.Coroutine.VerticalSpace 
import           Hoodle.Coroutine.Window
import           Hoodle.Device
import           Hoodle.GUI.Menu
import           Hoodle.GUI.Reflect
import           Hoodle.ModelAction.File

import           Hoodle.ModelAction.Page
import           Hoodle.ModelAction.Window 
import           Hoodle.Script
import           Hoodle.Script.Hook
import           Hoodle.Type.Canvas
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Enum
import           Hoodle.Type.Event
import           Hoodle.Type.HoodleState
import           Hoodle.Type.PageArrangement
import           Hoodle.Type.Predefined
import           Hoodle.Type.Undo
import           Hoodle.Type.Window 
import           Hoodle.Type.Widget
import           Hoodle.Widget.Clock
import           Hoodle.Widget.Dispatch 
import           Hoodle.Widget.Layer
import           Hoodle.Widget.PanZoom
--
import Prelude hiding ((.), id)

-- |
initCoroutine :: DeviceList 
              -> Window 
              -> Maybe FilePath 
              -> Maybe Hook 
              -> Int -- ^ maxundo 
              -> (Bool,Bool,Bool) -- ^ (xinputbool,usepz,uselyr)
              -> Statusbar -- ^ status bar 
              -> IO (EventVar,HoodleState,UIManager,VBox)
initCoroutine devlst window mfname mhook maxundo (xinputbool,usepz,uselyr) stbar = do 
  evar <- newEmptyMVar  
  putMVar evar Nothing 
  st0new <- set deviceList devlst  
            . set rootOfRootWindow window 
            . set callBack (eventHandler evar) 
            <$> emptyHoodleState 
  (ui,uicompsighdlr) <- getMenuUI evar    
  let st1 = set gtkUIManager ui st0new
      initcvs = set (canvasWidgets.widgetConfig.doesUsePanZoomWidget) usepz
              . set (canvasWidgets.widgetConfig.doesUseLayerWidget) uselyr
              $ defaultCvsInfoSinglePage { _canvasId = 1 } 
      initcvsbox = CanvasSinglePage initcvs
      st2 = set frameState (Node 1) 
            . updateFromCanvasInfoAsCurrentCanvas initcvsbox 
            $ st1 { _cvsInfoMap = M.empty } 
  (st3,cvs,_wconf) <- constructFrame st2 (view frameState st2)
  (st4,wconf') <- eventConnect st3 (view frameState st3)
  let st5 = set (settings.doesUseXInput) xinputbool 
          . set hookSet mhook 
          . set undoTable (emptyUndo maxundo)  
          . set frameState wconf' 
          . set rootWindow cvs 
          . set uiComponentSignalHandler uicompsighdlr 
          . set statusBar (Just stbar)
          $ st4
          
  st6 <- getFileContent mfname st5
  -- very dirty, need to be cleaned 
  let hdlst6 = view hoodleModeState st6
  hdlst7 <- resetHoodleModeStateBuffers hdlst6
  let st7 = set hoodleModeState hdlst7 st6
  -- 
  vbox <- vBoxNew False 0 
  -- 
  let startingXstate = set rootContainer (castToBox vbox) st7
  let startworld = world startingXstate . ReaderT $ 
                     (\(Arg DoEvent ev) -> guiProcess ev)  
  putMVar evar . Just $ (driver simplelogger startworld)
  return (evar,startingXstate,ui,vbox)


-- | initialization according to the setting 
initialize :: AllEvent -> MainCoroutine ()
initialize ev = do  
    case ev of 
      UsrEv Initialized -> do -- additional initialization goes here
        viewModeChange ToContSinglePage
        pageZoomChange FitWidth
        xst <- get 
        let Just sbar = view statusBar xst 
        cxtid <- liftIO $ statusbarGetContextId sbar "test"
        liftIO $ statusbarPush sbar cxtid "Hello there" 
        let ui = view gtkUIManager xst
        liftIO $ toggleSave ui False
        put (set isSaved True xst) 
      _ -> do ev' <- nextevent
              initialize (UsrEv ev')

-- |
guiProcess :: AllEvent -> MainCoroutine ()
guiProcess ev = do 
  initialize ev
  changePage (const 0)
  xstate <- get 
  reflectViewModeUI
  reflectPenModeUI
  reflectPenColorUI  
  reflectPenWidthUI
  let cinfoMap  = getCanvasInfoMap xstate
      assocs = M.toList cinfoMap 
      f (cid,cinfobox) = do let canvas = getDrawAreaFromBox cinfobox
                            (w',h') <- liftIO $ widgetGetSize canvas
                            defaultEventProcess (CanvasConfigure cid
                                                (fromIntegral w') 
                                                (fromIntegral h')) 
  mapM_ f assocs
  sequence_ (repeat dispatchMode)

-- | 
dispatchMode :: MainCoroutine () 
dispatchMode = get >>= return . hoodleModeStateEither . view hoodleModeState
                   >>= either (const viewAppendMode) (const selectMode)
                     
-- | 
viewAppendMode :: MainCoroutine () 
viewAppendMode = do 
  r1 <- nextevent 
  case r1 of 
    PenDown cid pbtn pcoord -> do 
      widgetCheckPen cid pcoord $ do 
        ptype <- getPenType 
        case (ptype,pbtn) of 
          (PenWork,PenButton1) -> penStart cid pcoord
          (PenWork,PenButton2) -> eraserStart cid pcoord 
          (PenWork,PenButton3) -> do 
            updateXState (return . set isOneTimeSelectMode YesBeforeSelect)
            modeChange ToSelectMode
            selectLassoStart PenButton3 cid pcoord
          (PenWork,EraserButton) -> eraserStart cid pcoord
          (PenWork,_) -> return () 
          (EraserWork,_)      -> eraserStart cid pcoord 
          (HighlighterWork,_) -> highlighterStart cid pcoord
          (VerticalSpaceWork,PenButton1) -> verticalSpaceStart cid pcoord 
          (VerticalSpaceWork,_) -> return () 
    TouchDown cid pcoord -> touchStart cid pcoord 
    PenMove cid pcoord -> disableTouch >> notifyLink cid pcoord  
    _ -> defaultEventProcess r1


disableTouch :: MainCoroutine () 
disableTouch = do 
    xst <- get 
    let devlst = view deviceList xst 
    let b = view (settings.doesUseTouch) xst 
    when b $ do         
      let nxst = set (settings.doesUseTouch) False xst 
      doIOaction $ \_ -> do
        setToggleUIForFlag "HANDA" (settings.doesUseTouch) nxst
        let touchstr = dev_touch_str devlst
        -- ad hoc
        when (touchstr /= "touch") $ do 
          readProcess "xinput" [ "disable", touchstr ] "" 
          return ()
        -- 
        return (UsrEv ActionOrdered)
      waitSomeEvent (\x -> case x of ActionOrdered -> True ; _ -> False)
      put nxst

-- |
selectMode :: MainCoroutine () 
selectMode = do 
  r1 <- nextevent 
  case r1 of 
    PenDown cid pbtn pcoord -> do 
      ptype <- liftM (view (selectInfo.selectType)) get
      case ptype of 
        SelectRectangleWork -> selectRectStart pbtn cid pcoord 
        SelectLassoWork -> selectLassoStart pbtn cid pcoord 
        _ -> return ()
    PenMove cid pcoord -> disableTouch >> notifyLink cid pcoord 
    TouchDown cid pcoord -> touchStart cid pcoord     
    PenColorChanged c -> do modify (penInfo.currentTool.penColor .~ c)
                            selectPenColorChanged c
    PenWidthChanged v -> do 
      w <- flip int2Point v . view (penInfo.penType) <$> get     
      modify (penInfo.currentTool.penWidth .~ w) 
      selectPenWidthChanged w 
    _ -> defaultEventProcess r1

-- |
defaultEventProcess :: UserEvent -> MainCoroutine ()
defaultEventProcess (UpdateCanvas cid) = invalidate cid   
defaultEventProcess (UpdateCanvasEfficient cid) = 
  invalidateInBBox Nothing Efficient cid   
defaultEventProcess (Menu m) = menuEventProcess m
defaultEventProcess (HScrollBarMoved cid v) = hscrollBarMoved cid v
defaultEventProcess (VScrollBarMoved cid v) = vscrollBarMoved cid v
defaultEventProcess (VScrollBarStart cid v) = vscrollStart cid v 
defaultEventProcess PaneMoveStart = paneMoveStart 
defaultEventProcess (CanvasConfigure cid w' h') = doCanvasConfigure cid (CanvasDimension (Dim w' h'))
defaultEventProcess ToViewAppendMode = modeChange ToViewAppendMode
defaultEventProcess ToSelectMode = modeChange ToSelectMode 
defaultEventProcess ToSinglePage = viewModeChange ToSinglePage
defaultEventProcess ToContSinglePage = viewModeChange ToContSinglePage
defaultEventProcess (AssignPenMode t) =  
    case t of 
      Left pm -> do 
        modify (penInfo.penType .~ pm)
        modeChange ToViewAppendMode
      Right sm -> do 
        modify (selectInfo.selectType .~ sm)
        modeChange ToSelectMode 
defaultEventProcess (PenColorChanged c) = do 
    modify (penInfo.currentTool.penColor .~ c)
    reflectPenColorUI
defaultEventProcess (PenWidthChanged v) = do 
    st <- get 
    let ptype = view (penInfo.penType) st
    let w = int2Point ptype v
    let stNew = set (penInfo.currentTool.penWidth) w st 
    put stNew 
defaultEventProcess (BackgroundStyleChanged bsty) = do
    modify (backgroundStyle .~ bsty)
    xstate <- get 
    let pgnum = view (currentCanvasInfo . unboxLens currentPageNum) xstate
        hdl = getHoodle xstate 
        pgs = view gpages hdl 
        cpage = getPageFromGHoodleMap pgnum hdl
        cbkg = view gbackground cpage
        bstystr = convertBackgroundStyleToByteString bsty 
        -- for the time being, I replace any background to solid background
        getnbkg :: RBackground -> RBackground 
        getnbkg (RBkgSmpl c _ _) = RBkgSmpl c bstystr Nothing 
        getnbkg (RBkgPDF _ _ _ _ _) = RBkgSmpl "white" bstystr Nothing 
        getnbkg (RBkgEmbedPDF _ _ _) = RBkgSmpl "white" bstystr Nothing 
        -- 
        npage = set gbackground (getnbkg cbkg) cpage 
        npgs = set (at pgnum) (Just npage) pgs 
        nhdl = set gpages npgs hdl 
    modeChange ToViewAppendMode     
    modify (set hoodleModeState (ViewAppendState nhdl))
    invalidateAll 
defaultEventProcess (GotContextMenuSignal ctxtmenu) = processContextMenu ctxtmenu
defaultEventProcess (GetHoodleFileInfo ref) = do 
  xst <- get
  let hdl = getHoodle xst 
      uuid = B.unpack (view ghoodleID hdl)
  case view (hoodleFileControl.hoodleFileName) xst of 
    Nothing -> liftIO $ writeIORef ref Nothing
    Just fp -> liftIO $ writeIORef ref (Just (uuid ++ "," ++ fp))
defaultEventProcess (GotLink mstr (x,y)) = gotLink mstr (x,y)    
defaultEventProcess (Sync ctime) = do 
  xst <- get
  case view (hoodleFileControl.lastSavedTime) xst of 
    Nothing -> return ()
    Just otime -> do 
      let dtime = diffUTCTime ctime otime
      if dtime < dtime_bound * 10 
        then return () 
        else do 
          let ioact = mkIOaction $ \evhandler -> do 
                postGUISync (evhandler (UsrEv FileReloadOrdered))
                return (UsrEv ActionOrdered)
          modify (tempQueue %~ enqueue ioact)
defaultEventProcess FileReloadOrdered = fileReload 
defaultEventProcess (CustomKeyEvent str) = do
    liftIO $ print str
    if | str == "[]:\"Super_L\"" -> do  
           xst <- liftM (over (settings.doesUseTouch) not) get 
           put xst 
           let action = mkIOaction $ \_evhandler -> do 
                 setToggleUIForFlag "HANDA" (settings.doesUseTouch) xst
                 return (UsrEv ActionOrdered)
           modify (tempQueue %~ enqueue action)
           waitSomeEvent (\x -> case x of ActionOrdered -> True ; _ -> False)    
           toggleTouch
       | str == "[]:\"1\"" -> colorfunc ColorBlack
       | str == "[]:\"2\"" -> colorfunc ColorBlue 
       | str == "[]:\"3\"" -> colorfunc ColorRed
       | str == "[]:\"4\"" -> colorfunc ColorGreen
       | str == "[]:\"5\"" -> colorfunc ColorGray
       | str == "[]:\"6\"" -> colorfunc ColorLightBlue
       | str == "[]:\"7\"" -> colorfunc ColorLightGreen
       | str == "[]:\"8\"" -> colorfunc ColorMagenta
       | str == "[]:\"9\"" -> colorfunc ColorOrange
       | str == "[]:\"0\"" -> colorfunc ColorYellow
       | str == "[]:\"minus\"" -> colorfunc ColorWhite
       | str == "[]:\"a\"" -> toolfunc PenWork 
       | str == "[]:\"b\"" -> toolfunc HighlighterWork
       | str == "[]:\"c\"" -> toolfunc EraserWork
       | str == "[]:\"d\"" -> toolfunc VerticalSpaceWork
       | otherwise -> return ()
  where 
    colorfunc c = doIOaction $ \_evhandler -> return (UsrEv (PenColorChanged c))
    toolfunc t = doIOaction $ \_evhandler -> return (UsrEv (AssignPenMode (Left t)))
defaultEventProcess (ImageFileDropped fname) = embedImage fname
defaultEventProcess ev = -- for debugging
                         do liftIO $ putStrLn "--- no default ---"
                            liftIO $ print ev 
                            liftIO $ putStrLn "------------------"
                            return () 

-- |
menuEventProcess :: MenuEvent -> MainCoroutine () 
menuEventProcess MenuQuit = do 
  xstate <- get
  liftIO $ putStrLn "MenuQuit called"
  if view isSaved xstate 
    then liftIO $ mainQuit
    else askQuitProgram
menuEventProcess MenuPreviousPage = changePage (\x->x-1)
menuEventProcess MenuNextPage =  changePage (+1)
menuEventProcess MenuFirstPage = changePage (const 0)
menuEventProcess MenuLastPage = do 
  totalnumofpages <- (either (M.size. view gpages) (M.size . view gselAll) 
                      . hoodleModeStateEither . view hoodleModeState) <$> get 
  changePage (const (totalnumofpages-1))
menuEventProcess MenuNewPageBefore = newPage PageBefore 
menuEventProcess MenuNewPageAfter = newPage PageAfter
menuEventProcess MenuDeletePage = deleteCurrentPage
menuEventProcess MenuExportPageSVG = exportCurrentPageAsSVG 
menuEventProcess MenuNew  = askIfSave fileNew 
menuEventProcess MenuAnnotatePDF = askIfSave fileAnnotatePDF
menuEventProcess MenuLoadPNGorJPG = fileLoadPNGorJPG
menuEventProcess MenuLoadSVG = fileLoadSVG
menuEventProcess MenuLaTeX = laTeXInput (100,100) (laTeXHeader <> "\n\n" <> laTeXFooter)
menuEventProcess MenuCombineLaTeX = combineLaTeXText 
menuEventProcess MenuUndo = undo 
menuEventProcess MenuRedo = redo
menuEventProcess MenuOpen = askIfSave fileOpen
menuEventProcess MenuSave = fileSave 
menuEventProcess MenuSaveAs = fileSaveAs
menuEventProcess MenuReload = fileReload 
menuEventProcess MenuExport = fileExport 
menuEventProcess MenuStartSync = fileStartSync
menuEventProcess MenuVersionSave = fileVersionSave 
menuEventProcess MenuShowRevisions = fileShowRevisions
menuEventProcess MenuShowUUID = fileShowUUID
-- 
menuEventProcess MenuCut = cutSelection
menuEventProcess MenuCopy = copySelection
menuEventProcess MenuPaste = pasteToSelection
menuEventProcess MenuDelete = deleteSelection
menuEventProcess MenuZoomIn = pageZoomChangeRel ZoomIn 
menuEventProcess MenuZoomOut = pageZoomChangeRel ZoomOut
menuEventProcess MenuNormalSize = pageZoomChange Original  
menuEventProcess MenuPageWidth = pageZoomChange FitWidth 
menuEventProcess MenuPageHeight = pageZoomChange FitHeight
menuEventProcess MenuHSplit = eitherSplit SplitHorizontal
menuEventProcess MenuVSplit = eitherSplit SplitVertical
menuEventProcess MenuDelCanvas = deleteCanvas
menuEventProcess MenuNewLayer = makeNewLayer 
menuEventProcess MenuNextLayer = gotoNextLayer 
menuEventProcess MenuPrevLayer = gotoPrevLayer
menuEventProcess MenuGotoLayer = startGotoLayerAt 
menuEventProcess MenuDeleteLayer = deleteCurrentLayer
menuEventProcess MenuUseXInput = do 
  xstate <- get 
  b <- updateFlagFromToggleUI "UXINPUTA" (settings.doesUseXInput)
  let cmap = getCanvasInfoMap xstate
      canvases = map (getDrawAreaFromBox) . M.elems $ cmap 
  if b
    then mapM_ (\x->liftIO $ widgetSetExtensionEvents x [ExtensionEventsAll]) canvases
    else mapM_ (\x->liftIO $ widgetSetExtensionEvents x [ExtensionEventsNone] ) canvases
menuEventProcess MenuUseTouch = toggleTouch
menuEventProcess MenuSmoothScroll = updateFlagFromToggleUI "SMTHSCRA" (settings.doesSmoothScroll) >> return ()
menuEventProcess MenuUsePopUpMenu = updateFlagFromToggleUI "POPMENUA" (settings.doesUsePopUpMenu) >> return ()
menuEventProcess MenuEmbedImage = updateFlagFromToggleUI "EBDIMGA" (settings.doesEmbedImage) >> return ()
menuEventProcess MenuEmbedPDF = updateFlagFromToggleUI "EBDPDFA" (settings.doesEmbedPDF) >> return ()
menuEventProcess MenuFollowLinks = updateFlagFromToggleUI "FLWLNKA" (settings.doesFollowLinks) >> return ()
menuEventProcess MenuKeepAspectRatio = updateFlagFromToggleUI "KEEPRATIOA" (settings.doesKeepAspectRatio) >> return ()
menuEventProcess MenuPressureSensitivity = updateFlagFromToggleUI "PRESSRSENSA" (penInfo.variableWidthPen) >> return ()  
menuEventProcess MenuRelaunch = liftIO $ relaunchApplication
menuEventProcess MenuColorPicker = colorPick 
menuEventProcess MenuFullScreen = fullScreen
menuEventProcess MenuText = textInput (100,100) "" 
menuEventProcess MenuAddLink = addLink
menuEventProcess MenuEmbedPredefinedImage = embedPredefinedImage 
menuEventProcess MenuEmbedPredefinedImage2 = embedPredefinedImage2 
menuEventProcess MenuEmbedPredefinedImage3 = embedPredefinedImage3 
menuEventProcess MenuApplyToAllPages = do 
    xstate <- get 
    let bsty = view backgroundStyle xstate 
    let hdl = getHoodle xstate 
        pgs = view gpages hdl 
        changeBkg cpage = 
          let cbkg = view gbackground cpage
              nbkg 
                | isRBkgSmpl cbkg = cbkg { rbkg_style = convertBackgroundStyleToByteString bsty }
                | otherwise = cbkg 
          in set gbackground nbkg cpage 
        npgs = fmap changeBkg pgs 
        nhdl = set gpages npgs hdl 
    modeChange ToViewAppendMode     
    modify (set hoodleModeState (ViewAppendState nhdl))
    invalidateAll 
menuEventProcess MenuEmbedAllPDFBkg = embedAllPDFBackground
menuEventProcess MenuTogglePanZoomWidget = (togglePanZoom . view (currentCanvas._1)) =<< get 
menuEventProcess MenuToggleLayerWidget = (toggleLayer . view (currentCanvas._1)) =<< get 
menuEventProcess MenuToggleClockWidget = (toggleClock . view (currentCanvas._1)) =<< get
menuEventProcess m = liftIO $ putStrLn $ "not implemented " ++ show m 


-- | 
colorPick :: MainCoroutine () 
colorPick = do mc <- colorPickerBox "Pen Color" 
               maybe (return ())  
                     (\c->modify (penInfo.currentTool.penColor .~ c)) 
                     mc 

-- | 
colorConvert :: Color -> PenColor 
colorConvert (Color r g b) = ColorRGBA (realToFrac r/65536.0) (realToFrac g/65536.0) (realToFrac b/65536.0) 1.0 

-- | 
colorPickerBox :: String -> MainCoroutine (Maybe PenColor) 
colorPickerBox msg = do 
   xst <- get 
   let pcolor = view ( penInfo.currentTool.penColor) xst   
   modify (tempQueue %~ enqueue (action pcolor)) >> go 
  where 
    action pcolor = 
      mkIOaction $ 
               \_evhandler -> do 
                 dialog <- colorSelectionDialogNew msg
                 csel <- colorSelectionDialogGetColor dialog
                 let (r,g,b,_a) =  convertPenColorToRGBA pcolor 
                     color = Color (floor (r*65535.0)) (floor (g*65535.0)) (floor (b*65535.0))
                
                 colorSelectionSetCurrentColor csel color
                 res <- dialogRun dialog 
                 mc <- case res of 
                         ResponseOk -> do 
                              clrsel <- colorSelectionDialogGetColor dialog 
                              clr <- colorSelectionGetCurrentColor clrsel     
                              return (Just (colorConvert clr))
                         _ -> return Nothing 
                 widgetDestroy dialog 
                 return (UsrEv (ColorChosen mc))
    go = do r <- nextevent                   
            case r of 
              ColorChosen mc -> return mc 
              UpdateCanvas cid -> -- this is temporary
                invalidateInBBox Nothing Efficient cid >> go
              _ -> go 
