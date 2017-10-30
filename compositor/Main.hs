{-# LANGUAGE ScopedTypeVariables #-}
module Main
where

import System.IO
import Foreign.Storable (Storable(peek))
import XdgShell
    ( XdgShell
    , xdgShellCreate
    )
import XWayland
    ( XWayShell
    , xwayShellCreate
    )


import Control.Monad.IO.Class (MonadIO)
import Waymonad
import Shared
import View

import Control.Monad.IO.Class (liftIO)
import Input (Input(..), inputCreate)
import Foreign.Ptr (Ptr, ptrToIntPtr)
import Data.IORef (newIORef, IORef, writeIORef, readIORef)

import Graphics.Wayland.Resource (resourceDestroy)
import Graphics.Wayland.WlRoots.Render.Matrix (withMatrix, matrixTranslate)
import Graphics.Wayland.WlRoots.Box (WlrBox (..))
import Graphics.Wayland.WlRoots.Render
    ( Renderer
    , doRender
    , isTextureValid
    , renderWithMatrix
    )
import Graphics.Wayland.WlRoots.Backend (Backend)
import Graphics.Wayland.WlRoots.XCursor
    ( WlrXCursor
    , getImages
    , WlrXCursorImage (..)
    )
import Graphics.Wayland.WlRoots.Render.Gles2 (rendererCreate)
import Graphics.Wayland.WlRoots.Compositor (WlrCompositor, compositorCreate)
import Graphics.Wayland.WlRoots.Shell
    ( WlrShell
    , --shellCreate
    )
import Graphics.Wayland.WlRoots.DeviceManager
    ( WlrDeviceManager
    , managerCreate
    )
import Graphics.Wayland.WlRoots.OutputLayout
    ( WlrOutputLayout
    , createOutputLayout
    , addOutputAuto
    )
import Graphics.Wayland.WlRoots.Output
    ( Output
    , makeOutputCurrent
    , swapOutputBuffers
    , getTransMatrix
    , setCursor
    )
import Graphics.Wayland.WlRoots.Surface
    ( surfaceGetTexture
    , withSurfaceMatrix
    , callbackGetResource
    , surfaceGetCallbacks
    , callbackGetCallback
    , getCurrentState
    , WlrSurface

    , subSurfaceGetSurface
    , surfaceGetSubs
    , subSurfaceGetBox
    )
import Graphics.Wayland.Server
    ( displayInitShm
    , DisplayServer
    , callbackDone
    )
import Control.Exception (bracket_)
import Control.Monad (void, when, forM_)

import qualified Data.IntMap.Strict as M

data Compositor = Compositor
    { compDisplay :: DisplayServer
    , compRenderer :: Ptr Renderer
    , compCompositor :: Ptr WlrCompositor
    , compShell :: Ptr WlrShell
    , compXdg :: XdgShell
    , compManager :: Ptr WlrDeviceManager
    , compXWayland :: XWayShell
    , compBackend :: Ptr Backend
    , compLayout :: Ptr WlrOutputLayout
    , compInput :: Input
    }



ptrToInt :: Num b => Ptr a -> b
ptrToInt = fromIntegral . ptrToIntPtr

renderOn :: Ptr Output -> Ptr Renderer -> IO a -> IO a
renderOn output rend act = bracket_
    (makeOutputCurrent output)
    (swapOutputBuffers output)
    (doRender rend output act)

outputHandleSurface :: Compositor -> Double -> Ptr Output -> Ptr WlrSurface -> Int -> Int -> IO ()
outputHandleSurface comp secs output surface x y = do
    texture <- surfaceGetTexture surface
    isValid <- isTextureValid texture
    when isValid $ withMatrix $ \trans -> do
        matrixTranslate trans (realToFrac x) (realToFrac y) 0
        withSurfaceMatrix surface (getTransMatrix output) trans $ \mat -> do
            renderWithMatrix (compRenderer comp) texture mat

        callbacks <- surfaceGetCallbacks =<< getCurrentState surface
        forM_ callbacks $ \callback -> do
            cb <- callbackGetCallback callback
            callbackDone cb (floor $ secs * 1000)
            res <- callbackGetResource callback
            resourceDestroy res

        subs <- surfaceGetSubs surface
        forM_ subs $ \sub -> do
            box <- subSurfaceGetBox sub
            subsurf <- subSurfaceGetSurface sub
            outputHandleSurface comp secs output subsurf (x + boxX box) (y + boxY box)

outputHandleView :: Compositor -> Double -> Ptr Output -> View -> IO ()
outputHandleView comp secs output view = do
    surface <- getViewSurface view
    box <- getViewBox view
    let x = boxX box
    let y = boxY box
    outputHandleSurface comp secs output surface x y
    renderViewAdditional (outputHandleSurface comp secs output) view


frameHandler :: IORef Compositor -> Double -> Ptr Output -> WayState ()
frameHandler compRef secs output = do
    -- First build the list of surface we can draw
    views <- get
    liftIO $ do
        comp <- readIORef compRef
        renderOn output (compRenderer comp) $ do
            mapM_ (outputHandleView comp secs output) views

adjustPosition :: MonadIO m => [View] -> WlrBox -> Bool -> m ()
adjustPosition [] _ _ = pure ()
adjustPosition [v] box _ = do
    let x = fromIntegral $ boxX box
    let y = fromIntegral $ boxY box
    moveView v x y

    let width = fromIntegral $ boxWidth box
    let height = fromIntegral $ boxHeight box
    resizeView v width height
adjustPosition (v:vs) box True = do
    let x = fromIntegral $ boxX box
    let y = fromIntegral $ boxY box
    moveView v x y

    let width = fromIntegral $ boxWidth box `div` 2
    let height = fromIntegral $ boxHeight box
    resizeView v width height
    adjustPosition vs box { boxX = floor x + floor width, boxWidth = floor width } False
adjustPosition (v:vs) box False = do
    let x = fromIntegral $ boxX box
    let y = fromIntegral $ boxY box
    moveView v x y

    let width = fromIntegral $ boxWidth box
    let height = fromIntegral $ boxHeight box `div` 2
    resizeView v width height
    adjustPosition vs box { boxY = floor y + floor height, boxHeight = floor height } True

reLayout :: WayState ()
reLayout = do
    views <- get
    adjustPosition (M.elems views) (WlrBox 0 0 1300 700) True


removeView :: Int -> WayState ()
removeView key = do
    modify $ M.delete key
    reLayout

addView ::  Int -> View -> WayState ()
addView key value = do
    modify $ M.insert key value
    reLayout


makeCompositor :: DisplayServer -> Ptr Backend -> WayState Compositor
makeCompositor display backend = do
    renderer <- liftIO $ rendererCreate backend
    void $ liftIO $ displayInitShm display
    comp <- liftIO $ compositorCreate display renderer
--    shell <- liftIO $ shellCreate display
    xdgShell <- xdgShellCreate display addView removeView
    devManager <- liftIO $ managerCreate display
    xway <- xwayShellCreate display comp addView removeView
    layout <- liftIO $ createOutputLayout
    input <- inputCreate display layout backend
    pure $ Compositor
        { compDisplay = display
        , compRenderer = renderer
        , compCompositor = comp
        , compShell = undefined -- shell
        , compXdg = xdgShell
        , compManager = devManager
        , compXWayland = xway
        , compBackend = backend
        , compLayout = layout
        , compInput = input
        }

setCursorImage :: Ptr Output -> Ptr WlrXCursor -> IO ()
setCursorImage output xcursor = do
    images <- getImages xcursor
    image <- peek $ head images

    setCursor
        output
        (xCursorImageBuffer image)
        (xCursorImageWidth image)
        (xCursorImageWidth image)
        (xCursorImageHeight image)
        (xCursorImageHotspotX image)
        (xCursorImageHotspotY image)

handleOutputAdd :: IORef Compositor -> WayStateRef -> Ptr Output -> IO FrameHandler
handleOutputAdd ref stateRef output = do
    comp <- readIORef ref

    setCursorImage output (inputXCursor $ compInput comp)
    addOutputAuto (compLayout comp) output

    pure $ \secs out ->
        runWayState (frameHandler ref secs out) stateRef

realMain :: IO ()
realMain = do
    stateRef <- newIORef mempty
    dpRef <- newIORef undefined
    compRef <- newIORef undefined
    launchCompositor ignoreHooks
        { displayHook = writeIORef dpRef
        , backendPreHook = \backend -> do
            dsp <- readIORef dpRef
            writeIORef compRef =<< runWayState (makeCompositor dsp backend) stateRef
        , outputAddHook = handleOutputAdd compRef stateRef
        }
    pure ()

main :: IO ()
main = realMain