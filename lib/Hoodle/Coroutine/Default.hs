{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.Default 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.Default where

import Control.Applicative ((<$>))
import Control.Monad.Coroutine
-- import Control.Monad.Coroutine.SuspensionFunctors
import qualified Control.Monad.State as St 
import Control.Monad.Trans
import qualified Data.IntMap as M
import Data.Maybe
import Control.Category
import Data.Label
import Prelude hiding ((.), id)
import Data.IORef
import Graphics.UI.Gtk hiding (get,set)
-- from hoodle-platform
import Data.Xournal.Simple (Dimension(..))
import Data.Xournal.Generic
-- from this package
import Hoodle.Accessor
import Hoodle.Coroutine.Callback
import Hoodle.Coroutine.Commit
import Hoodle.Coroutine.Draw
import Hoodle.Coroutine.Pen
import Hoodle.Coroutine.Eraser
import Hoodle.Coroutine.Highlighter
import Hoodle.Coroutine.Scroll
import Hoodle.Coroutine.Page
import Hoodle.Coroutine.Select
import Hoodle.Coroutine.File
import Hoodle.Coroutine.Mode
import Hoodle.Coroutine.Window
-- import Hoodle.Coroutine.Network
import Hoodle.Coroutine.Layer 
import Hoodle.Device
import Hoodle.GUI.Menu
import Hoodle.ModelAction.File
import Hoodle.ModelAction.Window 
import Hoodle.Script
import Hoodle.Script.Hook
import Hoodle.Type.Canvas
import Hoodle.Type.Clipboard
import Hoodle.Type.Coroutine
import Hoodle.Type.Enum
import Hoodle.Type.Event
import Hoodle.Type.Undo
import Hoodle.Type.Window 
import Hoodle.Type.XournalState
import Hoodle.Type.PageArrangement



-- |
initCoroutine :: DeviceList -> Window -> Maybe FilePath -> Maybe Hook 
                 -> Int -- ^ maxundo 
                 -> IO (TRef,HoodleState,UIManager,VBox)
initCoroutine devlst window mfname mhook maxundo  = do 
  
  tref <- newIORef Nothing -- undefined -- guiProcess 
  let st0new = set deviceList devlst  
            . set rootOfRootWindow window 
            . set callBack (bouncecallback tref) 
            $ emptyHoodleState 
  ui <- getMenuUI tref     
  putStrLn "hi"  
  let st1 = set gtkUIManager ui st0new
      initcvs = defaultCvsInfoSinglePage { _canvasId = 1 } 
      initcvsbox = CanvasInfoBox initcvs
      st2 = set frameState (Node 1) 
            . updateFromCanvasInfoAsCurrentCanvas initcvsbox 
            $ st1 { _cvsInfoMap = M.empty } 
  (st3,cvs,_wconf) <- constructFrame st2 (get frameState st2)
  (st4,wconf') <- eventConnect st3 (get frameState st3)
  let st5 = set hookSet mhook 
          . set undoTable (emptyUndo maxundo)  
          . set frameState wconf' 
          . set rootWindow cvs $ st4
  st6 <- getFileContent mfname st5
  let ui = get gtkUIManager st6
  vbox <- vBoxNew False 0 

  let startingXstate = set rootContainer (castToBox vbox) st6
  writeIORef tref (Just (\ev -> mapDown startingXstate (guiProcess ev)))

  return (tref,startingXstate,ui,vbox)


-- | 
initViewModeIOAction :: MainCoroutine HoodleState
initViewModeIOAction = do 
  oxstate <- getSt
  let ui = get gtkUIManager oxstate
  agr <- liftIO $ uiManagerGetActionGroups ui 
  Just ra <- liftIO $ actionGroupGetAction (head agr) "CONTA"
  let wra = castToRadioAction ra 
  connid <- liftIO $ wra `on` radioActionChanged $ \x -> do 
    y <- viewModeToMyEvent x 
    get callBack oxstate y 
    return () 
  let xstate = set pageModeSignal (Just connid) oxstate
  putSt xstate 
  return xstate 

-- |
initialize :: MyEvent -> MainCoroutine ()
initialize ev = do  
    liftIO $ putStrLn $ show ev 
    case ev of 
      Initialized -> return () 
      _ -> do ev <- await
              initialize ev 


-- |
guiProcess :: MyEvent -> MainCoroutine ()
guiProcess ev = do 
  initialize ev
  liftIO $ putStrLn "hi!"
  liftIO $ putStrLn "welcome to hoodle"
  changePage (const 0)
  xstate <- initViewModeIOAction 
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
dispatchMode = getSt >>= return . xojstateEither . get xournalstate
                     >>= either (const viewAppendMode) (const selectMode)
                     
-- | 

viewAppendMode :: MainCoroutine () 
viewAppendMode = do 
  r1 <- await 
  case r1 of 
    PenDown cid pbtn pcoord -> do 
      ptype <- getPenType 
      case (ptype,pbtn) of 
        (PenWork,PenButton1) -> penStart cid pcoord 
        (PenWork,PenButton2) -> eraserStart cid pcoord 
        (PenWork,PenButton3) -> do 
          updateXState (return . set isOneTimeSelectMode YesBeforeSelect)
          modeChange ToSelectMode
          selectLassoStart cid pcoord
        (PenWork,EraserButton) -> eraserStart cid pcoord
        (EraserWork,_)      -> eraserStart cid pcoord 
        (HighlighterWork,_) -> highlighterStart cid pcoord
        _ -> return () 
    _ -> defaultEventProcess r1

-- |

selectMode :: MainCoroutine () 
selectMode = do 
  r1 <- await 
  case r1 of 
    PenDown cid _pbtn pcoord -> do 
      ptype <- return . get (selectType.selectInfo) =<< lift St.get 
      case ptype of 
        SelectRectangleWork -> selectRectStart cid pcoord 
        SelectRegionWork -> selectLassoStart cid pcoord
        _ -> return ()
    PenColorChanged c -> selectPenColorChanged c
    PenWidthChanged v -> do 
      st <- getSt 
      let ptype = get (penType.penInfo) st
      let w = int2Point ptype v
      let stNew = set (penWidth.currentTool.penInfo) w st 
      putSt stNew 
      selectPenWidthChanged w
    _ -> defaultEventProcess r1


-- |

defaultEventProcess :: MyEvent -> MainCoroutine ()
defaultEventProcess (UpdateCanvas cid) = invalidate cid   
defaultEventProcess (Menu m) = menuEventProcess m
defaultEventProcess (HScrollBarMoved cid v) = hscrollBarMoved cid v
defaultEventProcess (VScrollBarMoved cid v) = vscrollBarMoved cid v
defaultEventProcess (VScrollBarStart cid _v) = vscrollStart cid 
defaultEventProcess PaneMoveStart = paneMoveStart 
defaultEventProcess (CanvasConfigure cid w' h') = 
  doCanvasConfigure cid (CanvasDimension (Dim w' h'))
defaultEventProcess ToViewAppendMode = modeChange ToViewAppendMode
defaultEventProcess ToSelectMode = modeChange ToSelectMode 
defaultEventProcess ToSinglePage = viewModeChange ToSinglePage
defaultEventProcess ToContSinglePage = viewModeChange ToContSinglePage
defaultEventProcess _ = return ()

-- |

askQuitProgram :: MainCoroutine () 
askQuitProgram = do 
  dialog <- liftIO $ messageDialogNew Nothing [DialogModal] 
                       MessageQuestion ButtonsOkCancel 
                       "Current canvas is not saved yet. Will you close hoodle?" 
  res <- liftIO $ dialogRun dialog
  case res of
    ResponseOk -> do 
      liftIO $ widgetDestroy dialog
      liftIO $ mainQuit
    _ -> do 
      liftIO $ widgetDestroy dialog
      return ()

-- |

menuEventProcess :: MenuEvent -> MainCoroutine () 
menuEventProcess MenuQuit = do 
  xstate <- getSt
  liftIO $ putStrLn "MenuQuit called"
  if get isSaved xstate 
    then liftIO $ mainQuit
    else askQuitProgram
menuEventProcess MenuPreviousPage = changePage (\x->x-1)
menuEventProcess MenuNextPage =  changePage (+1)
menuEventProcess MenuFirstPage = changePage (const 0)
menuEventProcess MenuLastPage = do 
  totalnumofpages <- (either (M.size. get g_pages) (M.size . get g_selectAll) 
                      . xojstateEither . get xournalstate) <$> getSt 
  changePage (const (totalnumofpages-1))
menuEventProcess MenuNewPageBefore = newPage PageBefore 
menuEventProcess MenuNewPageAfter = newPage PageAfter
menuEventProcess MenuDeletePage = deleteCurrentPage
menuEventProcess MenuNew  = askIfSave fileNew 
menuEventProcess MenuAnnotatePDF = askIfSave fileAnnotatePDF
menuEventProcess MenuUndo = undo 
menuEventProcess MenuRedo = redo
menuEventProcess MenuOpen = askIfSave fileOpen
menuEventProcess MenuSave = fileSave 
menuEventProcess MenuSaveAs = fileSaveAs
menuEventProcess MenuCut = cutSelection
menuEventProcess MenuCopy = copySelection
menuEventProcess MenuPaste = pasteToSelection
menuEventProcess MenuDelete = deleteSelection
-- menuEventProcess MenuNetCopy = clipCopyToNetworkClipboard
-- menuEventProcess MenuNetPaste = clipPasteFromNetworkClipboard
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
  xstate <- getSt 
  let ui = get gtkUIManager xstate 
  agr <- liftIO ( uiManagerGetActionGroups ui >>= \x ->
                    case x of 
                      [] -> error "No action group? "
                      y:_ -> return y )
  uxinputa <- liftIO (actionGroupGetAction agr "UXINPUTA") 
              >>= maybe (error "MenuUseXInput") (return . castToToggleAction)
  b <- liftIO $ toggleActionGetActive uxinputa
  let cmap = getCanvasInfoMap xstate
      canvases = map (getDrawAreaFromBox) . M.elems $ cmap 
  
  if b
    then mapM_ (\x->liftIO $ widgetSetExtensionEvents x [ExtensionEventsAll]) canvases
    else mapM_ (\x->liftIO $ widgetSetExtensionEvents x [ExtensionEventsNone] ) canvases
menuEventProcess MenuPressureSensitivity = updateXState pressSensAction 
  where pressSensAction xstate = do 
          let ui = get gtkUIManager xstate 
          agr <- liftIO ( uiManagerGetActionGroups ui >>= \x ->
                            case x of 
                              [] -> error "No action group? "
                              y:_ -> return y )
          pressrsensa <- liftIO (actionGroupGetAction agr "PRESSRSENSA") 
              >>= maybe (error "MenuPressureSensitivity") 
                        (return . castToToggleAction)
          b <- liftIO $ toggleActionGetActive pressrsensa
          return (set (variableWidthPen.penInfo) b xstate) 
menuEventProcess MenuRelaunch = liftIO $ relaunchApplication
menuEventProcess m = liftIO $ putStrLn $ "not implemented " ++ show m 


