{-# LANGUAGE TemplateHaskell #-}

module Application.HXournal.Type.Canvas where

import Application.HXournal.Type.Enum 
import Data.Sequence
import qualified Data.Map as M
import Data.Label 
import Prelude hiding ((.), id)

import Graphics.UI.Gtk

type CanvasId = Int 

data PenDraw = PenDraw { _points :: Seq (Double,Double) } 
             deriving (Show)
                      
emptyPenDraw :: PenDraw
emptyPenDraw = PenDraw empty

data PageMode = Continous | OnePage
              deriving (Show,Eq) 

data ZoomMode = Original | FitWidth | Zoom Double 
              deriving (Show,Eq)

data ViewInfo = ViewInfo { _pageMode :: PageMode
                         , _zoomMode :: ZoomMode
                         , _viewPortOrigin :: (Double,Double)
                         , _pageDimension :: (Double,Double) 
                         }
              deriving (Show)

data CanvasInfo = CanvasInfo { _canvasId :: CanvasId
                             , _drawArea :: DrawingArea
                             , _viewInfo :: ViewInfo 
                             , _currentPageNum :: Int
                             , _horizAdjustment :: Adjustment
                             , _vertAdjustment :: Adjustment 
                             }

emptyCanvasInfo :: CanvasInfo
emptyCanvasInfo = CanvasInfo 0 undefined undefined 0 undefined undefined 

type CanvasInfoMap = M.Map CanvasId CanvasInfo

data PenType = PenWork | HighlighterWork | EraserWork 
             deriving (Show,Eq)

data PenInfo = PenInfo { _penType :: PenType
                       , _penWidth :: Double
                       , _penColor :: PenColor } 
             deriving (Show) 

$(mkLabels [''PenDraw, ''ViewInfo, ''PenInfo, ''CanvasInfo])