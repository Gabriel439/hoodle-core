-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.Select 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-- selection-related coroutines  
-- 
-----------------------------------------------------------------------------

module Hoodle.Coroutine.Select where

-- from other package 
import           Control.Category
import           Control.Lens
import           Control.Monad
import           Control.Monad.Identity
import           Control.Monad.State
-- import           Data.Label
import           Data.Monoid 
import qualified Data.IntMap as M
import           Data.Sequence (Seq,(|>))
import qualified Data.Sequence as Sq (empty)
import           Data.Time.Clock
import           Graphics.Rendering.Cairo
import qualified Graphics.Rendering.Cairo.Matrix as Mat
import           Graphics.UI.Gtk hiding (get,set,disconnect)
-- from hoodle-platform
import           Control.Monad.Trans.Crtn 
import           Data.Hoodle.Simple (Dimension(..))
import           Data.Hoodle.Generic
import           Data.Hoodle.BBox
import           Graphics.Hoodle.Render.BBox
import           Graphics.Hoodle.Render.BBoxMapPDF
import           Graphics.Hoodle.Render.Generic
import           Graphics.Hoodle.Render.HitTest
import           Graphics.Hoodle.Render.Type
-- from this package
import           Hoodle.Accessor
import           Hoodle.Device
import           Hoodle.Coroutine.Commit
import           Hoodle.Coroutine.Draw
import           Hoodle.Coroutine.EventConnect
import           Hoodle.Coroutine.Mode
import           Hoodle.Coroutine.Pen
import           Hoodle.ModelAction.Layer 
import           Hoodle.ModelAction.Page
import           Hoodle.ModelAction.Select
import           Hoodle.Type.Alias
import           Hoodle.Type.Canvas
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Enum
import           Hoodle.Type.Event 
import           Hoodle.Type.PageArrangement
import           Hoodle.Type.HoodleState
import           Hoodle.View.Coordinate
import           Hoodle.View.Draw
-- 
import           Prelude hiding ((.), id)

-- |
createTempSelectRender :: PageNum -> CanvasGeometry -> Page EditMode
                          -> a 
                          -> MainCoroutine (TempSelectRender a) 
createTempSelectRender pnum geometry page x = do 
    let Dim cw ch = unCanvasDimension . canvasDim $ geometry
        xformfunc = cairoXform4PageCoordinate geometry pnum 
        renderfunc = do   
          xformfunc 
          cairoRenderOption (InBBoxOption Nothing) (InBBox page) 
          return ()
    tempsurface <- liftIO $ createImageSurface FormatARGB32 (floor cw) (floor ch)  
    let tempselection = TempSelectRender tempsurface (cw,ch) x
    liftIO $ updateTempSelection tempselection renderfunc True
    return tempselection 


-- | For Selection mode from pen mode with 2nd pen button
dealWithOneTimeSelectMode :: MainCoroutine ()     -- ^ main action 
                             -> MainCoroutine ()  -- ^ terminating action
                             -> MainCoroutine ()
dealWithOneTimeSelectMode action terminator = do 
  xstate <- get 
  case view isOneTimeSelectMode xstate of 
    NoOneTimeSelectMode -> action 
    YesBeforeSelect -> 
      action >> updateXState (return . set isOneTimeSelectMode YesAfterSelect)
    YesAfterSelect -> do 
      terminator 
      updateXState (return . set isOneTimeSelectMode NoOneTimeSelectMode) 
      modeChange ToViewAppendMode

-- | main mouse pointer click entrance in rectangular selection mode. 
--   choose either starting new rectangular selection or move previously 
--   selected selection. 
selectRectStart :: CanvasId -> PointerCoord -> MainCoroutine ()
selectRectStart cid = commonPenStart rectaction cid
  where rectaction cinfo pnum geometry (cidup,cidmove) (x,y) = do
          strs <- getAllStrokeBBoxInCurrentLayer
          ctime <- liftIO $ getCurrentTime
          let newSelectAction page = 
                dealWithOneTimeSelectMode 
                  (do tsel <- createTempSelectRender pnum geometry page [] 
                      newSelectRectangle cid pnum geometry cidmove cidup strs 
                                         (x,y) ((x,y),ctime) tsel
                      surfaceFinish (tempSurface tsel)) 
                  (disconnect cidmove >> disconnect cidup) 
          let 
              action (Right tpage) | hitInHandle tpage (x,y) = 
                case getULBBoxFromSelected tpage of 
                  Middle bbox ->  
                    maybe (return ()) 
                          (\handle -> startResizeSelect 
                                        handle cid pnum geometry cidmove cidup 
                                        bbox ((x,y),ctime) tpage)
                          (checkIfHandleGrasped bbox (x,y))
                  _ -> return () 
              action (Right tpage) | hitInSelection tpage (x,y) = do
                startMoveSelect cid pnum geometry cidmove cidup ((x,y),ctime) tpage
              action (Right tpage) | otherwise = newSelectAction (gcast tpage :: Page EditMode )
              action (Left page) = newSelectAction page
          xstate <- get 
          let hdlmodst = view hoodleModeState xstate 
          let epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst 
          action epage

-- | 
newSelectRectangle :: CanvasId
                   -> PageNum 
                   -> CanvasGeometry
                   -> ConnectId DrawingArea -> ConnectId DrawingArea
                   -> [StrokeBBox] 
                   -> (Double,Double)
                   -> ((Double,Double),UTCTime)
                   -> TempSelection 
                   -> MainCoroutine () 
newSelectRectangle cid pnum geometry connidmove connidup strs orig 
                   (prev,otime) tempselection = do  
    r <- nextevent
    xst <- get 
    boxAction (fsingle r xst) . getCanvasInfo cid $ xst
  where 
    fsingle r xstate cinfo = penMoveAndUpOnly r pnum geometry defact
                               (moveact xstate cinfo) (upact xstate cinfo)
    defact = newSelectRectangle cid pnum geometry connidmove connidup strs orig 
                         (prev,otime) tempselection 
    moveact _xstate _cinfo (_pcoord,(x,y)) = do 
      let bbox = BBox orig (x,y)
          hittestbbox = mkHitTestInsideBBox bbox strs
          hittedstrs = concat . map unHitted . getB $ hittestbbox
      page <- getCurrentPageCvsId cid
      let (fstrs,sstrs) = separateFS $ getDiffStrokeBBox (tempSelected tempselection) hittedstrs 
      (willUpdate,(ncoord,ntime)) <- liftIO $ getNewCoordTime (prev,otime) (x,y)
      when ((not.null) fstrs || (not.null) sstrs ) $ do 
        let xformfunc = cairoXform4PageCoordinate geometry pnum 
            ulbbox = unUnion . mconcat . fmap (Union .Middle . flip inflate 5 . strokebbox_bbox) $ fstrs
            renderfunc = do   
              xformfunc 
              case ulbbox of 
                Top -> do 
                  cairoRenderOption (InBBoxOption Nothing) (InBBox page) 
                  mapM_ renderSelectedStroke hittedstrs
                Middle sbbox -> do 
                  let redrawee = filter (hitTestBBoxBBox sbbox.strokebbox_bbox) hittedstrs  
                  cairoRenderOption (InBBoxOption (Just sbbox)) (InBBox page)
                  clipBBox (Just sbbox)
                  mapM_ renderSelectedStroke redrawee 
                Bottom -> return ()
              mapM_ renderSelectedStroke sstrs 
        liftIO $ updateTempSelection tempselection renderfunc False
      when willUpdate $  
        invalidateTemp cid (tempSurface tempselection) 
                           (renderBoxSelection bbox) 
      newSelectRectangle cid pnum geometry connidmove connidup strs orig 
                         (ncoord,ntime)
                         tempselection { tempSelectInfo = hittedstrs }
    upact xstate cinfo pcoord = do       
      let (_,(x,y)) = runIdentity $ 
            skipIfNotInSamePage pnum geometry pcoord 
                                (return (pcoord,prev)) return
          epage = getCurrentPageEitherFromHoodleModeState cinfo (view hoodleModeState xstate)
          cpn = view currentPageNum cinfo 
          bbox = BBox orig (x,y)
          hittestbbox = mkHitTestInsideBBox bbox strs
          selectstrs = fmapAL unNotHitted id hittestbbox
          SelectState thdl = view hoodleModeState xstate
          newpage = case epage of 
                      Left pagebbox -> makePageSelectMode pagebbox selectstrs 
                      Right tpage -> 
                        let ls = glayers tpage 
                            currlayer = gselectedlayerbuf ls
                            newlayer = GLayerBuf (view g_buffer currlayer) (TEitherAlterHitted (Right selectstrs))
                            npage = tpage { glayers = ls { gselectedlayerbuf = newlayer } } 
                        in npage
          newthdl = thdl { gselectSelected = Just (cpn,newpage) } 
          ui = view gtkUIManager xstate
      liftIO $ toggleCutCopyDelete ui (isAnyHitted  selectstrs)
      put . set hoodleModeState (SelectState newthdl) 
            =<< (liftIO (updatePageAll (SelectState newthdl) xstate))
      disconnect connidmove
      disconnect connidup 
      invalidateAll 


-- | prepare for moving selection 
startMoveSelect :: CanvasId 
                   -> PageNum 
                   -> CanvasGeometry 
                   -> ConnectId DrawingArea
                   -> ConnectId DrawingArea
                   -> ((Double,Double),UTCTime) 
                   -> Page SelectMode
                   -> MainCoroutine () 
startMoveSelect cid pnum geometry cidmove cidup ((x,y),ctime) tpage = do  
    strimage <- liftIO $ mkStrokesNImage geometry tpage
    tsel <- createTempSelectRender pnum geometry
              (gcast tpage :: Page EditMode) 
              strimage 
    moveSelect cid pnum geometry cidmove cidup (x,y) ((x,y),ctime) tsel 
    surfaceFinish (tempSurface tsel)                  
    surfaceFinish (imageSurface strimage)

-- | 
moveSelect :: CanvasId
              -> PageNum -- ^ starting pagenum 
              -> CanvasGeometry
              -> ConnectId DrawingArea 
              -> ConnectId DrawingArea
              -> (Double,Double)
              -> ((Double,Double),UTCTime)
              -> TempSelectRender StrokesNImage
              -> MainCoroutine ()
moveSelect cid pnum geometry connidmove connidup orig@(x0,y0) 
           (prev,otime) tempselection = do
    xst <- get
    r <- nextevent 
    boxAction (fsingle r xst) . getCanvasInfo cid $ xst 
  where 
    fsingle r xstate cinfo = 
      penMoveAndUpInterPage r pnum geometry defact (moveact xstate cinfo) (upact xstate cinfo) 
    defact = moveSelect cid pnum geometry connidmove connidup orig (prev,otime) 
               tempselection
    moveact _xstate _cinfo oldpgn pcpair@(newpgn,PageCoord (px,py)) = do 
      let (x,y) 
            | oldpgn == newpgn = (px,py) 
            | otherwise = 
              let DeskCoord (xo,yo) = page2Desktop geometry (oldpgn,PageCoord (0,0))
                  DeskCoord (xn,yn) = page2Desktop geometry pcpair 
              in (xn-xo,yn-yo)
      
      (willUpdate,(ncoord,ntime)) <- liftIO $ getNewCoordTime (prev,otime) (x,y) 
      when willUpdate $ do 
        let sfunc = offsetFunc (x-x0,y-y0)
            xform = unCvsCoord . desktop2Canvas geometry
                    . page2Desktop geometry . (,) pnum . PageCoord
            (c1,c2) = xform (sfunc (0,0))
            (a1',a2') = xform (sfunc (1,0))
            (a1,a2) = (a1'-c1,a2'-c2)
            (b1',b2') = xform (sfunc (0,1))
            (b1,b2) = (b1'-c1,b2'-c2)
            xformmat = Mat.Matrix a1 a2 b1 b2 c1 c2 
        invalidateTempBasePage cid (tempSurface tempselection) pnum 
          (drawTempSelectImage geometry tempselection xformmat) 
      moveSelect cid pnum geometry connidmove connidup orig (ncoord,ntime) 
        tempselection
    upact :: (ViewMode a) => HoodleState -> CanvasInfo a -> PointerCoord -> MainCoroutine () 
    upact xst cinfo pcoord =  
      switchActionEnteringDiffPage pnum geometry pcoord (return ()) 
        (chgaction xst cinfo) 
        (ordaction xst cinfo)
    chgaction :: (ViewMode a) => HoodleState -> CanvasInfo a -> PageNum -> (PageNum,PageCoordinate) -> MainCoroutine () 
    chgaction xstate cinfo oldpgn (newpgn,PageCoord (x,y)) = do 
      let hdlmodst@(SelectState thdl) = view hoodleModeState xstate
          epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst
      (xstate1,nthdl1,selectedstrs) <- 
        case epage of 
          Right oldtpage -> do 
            let strs = getSelectedStrokes oldtpage
            let oldtpage' = deleteSelected oldtpage
            nthdl <- liftIO $ updateTempHoodleSelectIO thdl oldtpage' (unPageNum oldpgn)
            xst <- return . set hoodleModeState (SelectState nthdl)
                     =<< (liftIO (updatePageAll (SelectState nthdl) xstate)) 
            return (xst,nthdl,strs)       
          Left _ -> error "this is impossible, in moveSelect" 
      let maction = do 
            page <- M.lookup (unPageNum newpgn) (view g_selectAll nthdl1)
            let (mcurrlayer,npage) = getCurrentLayerOrSet page
            currlayer <- mcurrlayer 
            let oldstrs = view g_bstrokes currlayer
            let newstrs = map (changeStrokeBy (offsetFunc (x-x0,y-y0))) selectedstrs 
                alist = oldstrs :- Hitted newstrs :- Empty 
                ntpage = makePageSelectMode npage alist  
                coroutineaction = do 
                  nthdl2 <- liftIO $ updateTempHoodleSelectIO nthdl1 ntpage (unPageNum newpgn)  
                  let ncinfo = set currentPageNum (unPageNum newpgn) $ cinfo 
                      cmap = getCanvasInfoMap xstate1 
                      cmap' = M.adjust (const (CanvasInfoBox ncinfo)) cid cmap
                      xst = maybe xstate1 id $ setCanvasInfoMap cmap' xstate1
                  return . set hoodleModeState (SelectState nthdl2)
                    =<< (liftIO (updatePageAll (SelectState nthdl2) xst)) 
            return coroutineaction
      xstate2 <- maybe (return xstate1) id maction 
      commit xstate2
      disconnect connidmove
      disconnect connidup 
      invalidateAll 
      
    ordaction xstate cinfo _pgn (_cpn,PageCoord (x,y)) = do 
      let offset = (x-x0,y-y0)
          hdlmodst@(SelectState thdl) = view hoodleModeState xstate
          epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst
          pagenum = view currentPageNum cinfo
      case epage of 
        Right tpage -> do 
          let newtpage = changeSelectionByOffset offset tpage 
          newthdl <- liftIO $ updateTempHoodleSelectIO thdl newtpage pagenum 
          commit . set hoodleModeState (SelectState newthdl)
                 =<< (liftIO (updatePageAll (SelectState newthdl) xstate))
        Left _ -> error "this is impossible, in moveSelect" 
      disconnect connidmove
      disconnect connidup 
      invalidateAll 
      

-- | prepare for resizing selection 
startResizeSelect :: Handle 
                     -> CanvasId 
                     -> PageNum 
                     -> CanvasGeometry 
                     -> ConnectId DrawingArea
                     -> ConnectId DrawingArea
                     -> BBox
                     -> ((Double,Double),UTCTime) 
                     -> Page SelectMode
                     -> MainCoroutine () 
startResizeSelect handle cid pnum geometry cidmove cidup bbox 
                  ((x,y),ctime) tpage = do  
    strimage <- liftIO $ mkStrokesNImage geometry tpage  
    tsel <- createTempSelectRender pnum geometry 
              (gcast tpage :: Page EditMode) 
              strimage 
    resizeSelect handle cid pnum geometry cidmove cidup bbox ((x,y),ctime) tsel 
    surfaceFinish (tempSurface tsel)  
    surfaceFinish (imageSurface strimage)
  

-- | 
resizeSelect :: Handle 
                -> CanvasId
                -> PageNum 
                -> CanvasGeometry
                -> ConnectId DrawingArea 
                -> ConnectId DrawingArea
                -> BBox
                -> ((Double,Double),UTCTime)
                -> TempSelectRender StrokesNImage
                -> MainCoroutine ()
resizeSelect handle cid pnum geometry connidmove connidup origbbox 
             (prev,otime) tempselection = do
    xst <- get
    r <- nextevent 
    boxAction (fsingle r xst) . getCanvasInfo cid $ xst
  where
    fsingle r xstate cinfo = penMoveAndUpOnly r pnum geometry defact (moveact xstate cinfo) (upact xstate cinfo)
    defact = resizeSelect handle cid pnum geometry connidmove connidup 
               origbbox (prev,otime) tempselection
    moveact _xstate _cinfo (_pcoord,(x,y)) = do 
      (willUpdate,(ncoord,ntime)) <- liftIO $ getNewCoordTime (prev,otime) (x,y) 
      when willUpdate $ do 
        let newbbox = getNewBBoxFromHandlePos handle origbbox (x,y)      
            sfunc = scaleFromToBBox origbbox newbbox
            xform = unCvsCoord . desktop2Canvas geometry
                    . page2Desktop geometry . (,) pnum . PageCoord
            (c1,c2) = xform (sfunc (0,0))
            (a1',a2') = xform (sfunc (1,0))
            (a1,a2) = (a1'-c1,a2'-c2)
            (b1',b2') = xform (sfunc (0,1))
            (b1,b2) = (b1'-c1,b2'-c2)
            xformmat = Mat.Matrix a1 a2 b1 b2 c1 c2 
        invalidateTemp cid (tempSurface tempselection) 
                           (drawTempSelectImage geometry tempselection 
                              xformmat)
      resizeSelect handle cid pnum geometry connidmove connidup 
                   origbbox (ncoord,ntime) tempselection
    upact xstate cinfo pcoord = do 
      let (_,(x,y)) = runIdentity $ 
            skipIfNotInSamePage pnum geometry pcoord 
                                (return (pcoord,prev)) return
          newbbox = getNewBBoxFromHandlePos handle origbbox (x,y)
          hdlmodst@(SelectState thdl) = view hoodleModeState xstate
          epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst
          pagenum = view currentPageNum cinfo
      case epage of 
        Right tpage -> do 
          let sfunc = scaleFromToBBox origbbox newbbox
          let newtpage = changeSelectionBy sfunc tpage 
          newthdl <- liftIO $ updateTempHoodleSelectIO thdl newtpage pagenum 
          commit . set hoodleModeState (SelectState newthdl)
                 =<< (liftIO (updatePageAll (SelectState newthdl) xstate))
        Left _ -> error "this is impossible, in resizeSelect" 
      disconnect connidmove
      disconnect connidup 
      invalidateAll
      return ()    

  
-- | 
selectPenColorChanged :: PenColor -> MainCoroutine () 
selectPenColorChanged pcolor = do 
  xstate <- get
  let SelectState thdl = view hoodleModeState xstate 
      Just (n,tpage) = gselectSelected thdl
      slayer = gselectedlayerbuf . glayers $ tpage
  case unTEitherAlterHitted . view g_bstrokes $ slayer of 
    Left _ -> return () 
    Right alist -> do 
      let alist' = fmapAL id 
                     (Hitted . map (changeStrokeColor pcolor) . unHitted) alist
          newlayer = Right alist'
          ls = glayers tpage 
          newpage = tpage { glayers = ls { gselectedlayerbuf = GLayerBuf (view g_buffer slayer) (TEitherAlterHitted newlayer) }} 
      newthdl <- liftIO $ updateTempHoodleSelectIO thdl newpage n
      commit =<< liftIO (updatePageAll (SelectState newthdl)
                        . set hoodleModeState (SelectState newthdl) $ xstate )
      invalidateAll 
          
-- | 
selectPenWidthChanged :: Double -> MainCoroutine () 
selectPenWidthChanged pwidth = do 
  xstate <- get
  let SelectState thdl = view hoodleModeState xstate 
      Just (n,tpage) = gselectSelected thdl
      slayer = gselectedlayerbuf . view g_layers $ tpage
  case unTEitherAlterHitted . view g_bstrokes $ slayer  of 
    Left _ -> return () 
    Right alist -> do 
      let alist' = fmapAL id 
                     (Hitted . map (changeStrokeWidth pwidth) . unHitted) alist
          newlayer = Right alist'
          ls = view g_layers tpage 
          newpage = tpage { glayers = ls { gselectedlayerbuf = GLayerBuf (view g_buffer slayer) (TEitherAlterHitted newlayer) }} 
      newthdl <- liftIO $ updateTempHoodleSelectIO thdl newpage n          
      commit =<< liftIO (updatePageAll (SelectState newthdl) 
                         . set hoodleModeState (SelectState newthdl) $ xstate )
      invalidateAll 

-- | main mouse pointer click entrance in lasso selection mode. 
--   choose either starting new rectangular selection or move previously 
--   selected selection. 
selectLassoStart :: CanvasId -> PointerCoord -> MainCoroutine ()
selectLassoStart cid = commonPenStart lassoAction cid 
  where lassoAction cinfo pnum geometry (cidup,cidmove) (x,y) = do 
          strs <- getAllStrokeBBoxInCurrentLayer
          ctime <- liftIO $ getCurrentTime
          let newSelectAction page =    
                dealWithOneTimeSelectMode 
                  (do tsel <- createTempSelectRender pnum geometry page [] 
                      newSelectLasso cinfo pnum geometry cidmove cidup strs 
                                     (x,y) ((x,y),ctime) (Sq.empty |> (x,y)) tsel
                      surfaceFinish (tempSurface tsel))
                  (disconnect cidmove >> disconnect cidup )
          let action (Right tpage) | hitInSelection tpage (x,y) = 
                startMoveSelect cid pnum geometry cidmove cidup ((x,y),ctime) tpage
              action (Right tpage) | hitInHandle tpage (x,y) = 
                case getULBBoxFromSelected tpage of 
                  Middle bbox ->  
                    maybe (return ()) 
                          (\handle -> startResizeSelect 
                                        handle cid pnum geometry cidmove cidup 
                                        bbox ((x,y),ctime) tpage)
                          (checkIfHandleGrasped bbox (x,y))
                  _ -> return () 
              action (Right tpage) | otherwise = newSelectAction (gcast tpage :: Page EditMode )
              action (Left page) = newSelectAction page
          xstate <- get 
          let hdlmodst = view hoodleModeState xstate 
          let epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst 
          action epage
          
-- | 
newSelectLasso :: (ViewMode a) => CanvasInfo a
                  -> PageNum 
                  -> CanvasGeometry
                  -> ConnectId DrawingArea -> ConnectId DrawingArea
                  -> [StrokeBBox] 
                  -> (Double,Double)
                  -> ((Double,Double),UTCTime)
                  -> Seq (Double,Double)
                  -> TempSelection 
                  -> MainCoroutine ()
newSelectLasso cvsInfo pnum geometry cidmove cidup strs orig (prev,otime) lasso tsel = do
    r <- nextevent 
    fsingle r cvsInfo 
  where  
    fsingle r cinfo = penMoveAndUpOnly r pnum geometry defact
                        (moveact cinfo) (upact cinfo)
    defact = newSelectLasso cvsInfo pnum geometry cidmove cidup strs orig 
               (prev,otime) lasso tsel
    moveact cinfo (_pcoord,(x,y)) = do 
      let nlasso = lasso |> (x,y)
      (willUpdate,(ncoord,ntime)) <- liftIO $ getNewCoordTime (prev,otime) (x,y)
      when willUpdate $ do 
        invalidateTemp (view canvasId cinfo) (tempSurface tsel) (renderLasso nlasso) 
      newSelectLasso cinfo pnum geometry cidmove cidup strs orig 
                     (ncoord,ntime) nlasso tsel
    upact cinfo pcoord = do 
      xstate <- get 
      let (_,(x,y)) = runIdentity $ 
            skipIfNotInSamePage pnum geometry pcoord 
                                (return (pcoord,prev)) return
          nlasso = lasso |> (x,y)
          hdlmodst = view hoodleModeState xstate 
          epage = getCurrentPageEitherFromHoodleModeState cinfo hdlmodst
          cpn = view currentPageNum cinfo 
          hittestlasso = mkHitTestAL (hitLassoStroke (nlasso |> orig)) strs
          selectstrs = fmapAL unNotHitted id hittestlasso
          SelectState thdl = view hoodleModeState xstate
          newpage = case epage of 
                      Left pagebbox -> 
                        let (mcurrlayer,npagebbox) = getCurrentLayerOrSet pagebbox
                            currlayer = maybe (error "newSelectLasso") id mcurrlayer 
                            newlayer = GLayerBuf (view g_buffer currlayer) (TEitherAlterHitted (Right selectstrs))
                            tpg = gcast npagebbox 
                            ls = view g_layers tpg 
                            npg = tpg { glayers = ls { gselectedlayerbuf = newlayer}  }
                        in npg 
                      Right tpage -> 
                        let ls = glayers tpage 
                            currlayer = gselectedlayerbuf ls
                            newlayer = GLayerBuf (view g_buffer currlayer) (TEitherAlterHitted (Right selectstrs))
                            npage = tpage { glayers = ls { gselectedlayerbuf = newlayer } } 
                        in npage
          newthdl = thdl { gselectSelected = Just (cpn,newpage) } 
      let ui = view gtkUIManager xstate
      liftIO $ toggleCutCopyDelete ui (isAnyHitted  selectstrs)
      put . set hoodleModeState (SelectState newthdl) 
            =<< (liftIO (updatePageAll (SelectState newthdl) xstate))
      disconnect cidmove
      disconnect cidup 
      invalidateAll 

