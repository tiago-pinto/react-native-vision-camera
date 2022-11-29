#import "SkiaMetalCanvasProvider.h"

#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>

#import <include/core/SkColorSpace.h>
#import <include/core/SkSurface.h>
#import <include/core/SkCanvas.h>
#import <include/core/SkFont.h>
#import <include/gpu/GrDirectContext.h>

#import "SkImageHelpers.h"

#include <memory>

// 1 = show FPS counter in Skia Preview, 0 = don't
#define DEBUG_FPS 1

SkiaMetalCanvasProvider::SkiaMetalCanvasProvider(): std::enable_shared_from_this<SkiaMetalCanvasProvider>() {
  _device = MTLCreateSystemDefaultDevice();
  _commandQueue = id<MTLCommandQueue>(CFRetain((GrMTLHandle)[_device newCommandQueue]));

  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wunguarded-availability-new"
  _layer = [CAMetalLayer layer];
  #pragma clang diagnostic pop

  _layer.framebufferOnly = NO;
  _layer.device = _device;
  _layer.opaque = false;
  _layer.contentsScale = getPixelDensity();
  _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  
  _isValid = true;
  
  _displayLink = [[VisionDisplayLink alloc] init];
}

SkiaMetalCanvasProvider::~SkiaMetalCanvasProvider() {
  _isValid = false;
  NSLog(@"VisionCamera: Stopping SkiaMetalCanvasProvider DisplayLink...");
  [_displayLink stop];
}

void SkiaMetalCanvasProvider::start() {
  NSLog(@"VisionCamera: Starting SkiaMetalCanvasProvider DisplayLink...");
  [_displayLink start:[weakThis = weak_from_this()](double time) {
    auto thiz = weakThis.lock();
    if (thiz) {
      thiz->render();
    }
  }];
}

/**
 Callback from the DisplayLink - replaces a new drawable on the screen.
 */
void SkiaMetalCanvasProvider::render() {
  @autoreleasepool {
    // Blocks until the next Frame is ready (16ms at 60 FPS)
    auto tempDrawable = [_layer nextDrawable];
    
    // After we got a new Drawable (from blocking call), make sure we're still valid
    if (!_isValid) return;
    
    std::unique_lock lock(_drawableMutex);
    _currentDrawable = tempDrawable;
    lock.unlock();
  }
}

float SkiaMetalCanvasProvider::getPixelDensity() {
  return UIScreen.mainScreen.scale;
}

/**
 Render to a canvas. This uses the current in-memory drawable (received from the DisplayLink render loop) and pushes updates.
 If no new drawable is available, it can push to the same drawable multiple times.
 The buffer is expected to be in RGB (`BGRA_8888`) format.
 While rendering, `drawCallback` will be invoked with a Skia Canvas instance which can be used for Frame Processing (JS).
 */
void SkiaMetalCanvasProvider::renderFrameToCanvas(CMSampleBufferRef sampleBuffer, const std::function<void(SkCanvas*)>& drawCallback) {
  if (_width == -1 && _height == -1) {
    return;
  }

  if (_skContext == nullptr) {
    GrContextOptions grContextOptions;
    _skContext = GrDirectContext::MakeMetal((__bridge void*)_device,
                                            (__bridge void*)_commandQueue,
                                            grContextOptions);
  }

  // Wrap in auto release pool since we want the system to clean up after rendering
  // and not wait until later - we've seen some example of memory usage growing very
  // fast in the simulator without this.
  @autoreleasepool {
    // Lock Mutex to block the runLoop from overwriting the _currentDrawable
    std::lock_guard lockGuard(_drawableMutex);
    
    // Get the drawable to keep the reference/retain ownership here.
    id<CAMetalDrawable> currentDrawable = _currentDrawable;
    
    // No Drawable is ready. Abort
    if (currentDrawable == nullptr) {
      return;
    }
    
    // Get & Lock the writeable Texture from the Metal Drawable
    GrMtlTextureInfo fbInfo;
    fbInfo.fTexture.retain((__bridge void*)currentDrawable.texture);
    GrBackendRenderTarget backendRT(_layer.drawableSize.width,
                                    _layer.drawableSize.height,
                                    1,
                                    fbInfo);
    
    // Create a Skia Surface from the writable Texture
    auto skSurface = SkSurface::MakeFromBackendRenderTarget(_skContext.get(),
                                                            backendRT,
                                                            kTopLeft_GrSurfaceOrigin,
                                                            kBGRA_8888_SkColorType,
                                                            nullptr,
                                                            nullptr);
    
    if (skSurface == nullptr || skSurface->getCanvas() == nullptr) {
      throw std::runtime_error("Skia surface could not be created from parameters.");
    }
    
    // Get the Frame's PixelBuffer
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    if (pixelBuffer == nil) {
      throw std::runtime_error("drawFrame: Pixel Buffer is corrupt/empty.");
    }
    
    // Lock the Frame's PixelBuffer for the duration of the Frame Processor so the user can safely do operations on it
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    // Converts the CMSampleBuffer to an SkImage - RGB.
    auto image = SkImageHelpers::convertCMSampleBufferToSkImage(_skContext.get(), sampleBuffer);
    
    auto canvas = skSurface->getCanvas();
    auto surface = canvas->getSurface();
    
    // Calculate Center Crop (aspectRatio: cover) transform
    auto sourceRect = SkRect::MakeXYWH(0, 0, image->width(), image->height());
    auto destinationRect = SkRect::MakeXYWH(0, 0, surface->width(), surface->height());
    sourceRect = SkImageHelpers::createCenterCropRect(sourceRect, destinationRect);
    
    auto offsetX = -sourceRect.left();
    auto offsetY = -sourceRect.top();

    
    // The Canvas is equal to the View size, where-as the Frame has a different size (e.g. 4k)
    // We scale the Canvas to the exact dimensions of the Frame so that the user can use the Frame as a coordinate system
    canvas->save();
    
    auto scaleW = static_cast<double>(surface->width()) / (image->width());
    auto scaleH = static_cast<double>(surface->height()) / (image->height());
    auto scale = MAX(scaleW, scaleH);
    canvas->scale(scale, scale);
    canvas->translate(offsetX, offsetY);
    
    // Draw the Image into the Frame (aspectRatio: cover)
    // The Frame Processor might draw the Frame again (through render()) to pass a custom paint/shader,
    // but that'll just overwrite the existing one - no need to worry.
    canvas->drawImage(image, 0, 0);
    
    // Call the JS Frame Processor.
    drawCallback(canvas);
    
    // Restore the scale & transform
    canvas->restore();
    
#if DEBUG
#if DEBUG_FPS
    // Draw FPS on screen
    int fps = static_cast<int>(round(_displayLink.currentFps));
    int targetFps = static_cast<int>(round(_displayLink.targetFps));
    SkString string("FPS: " + std::to_string(fps) + " / " + std::to_string(targetFps));
    auto typeface = SkTypeface::MakeFromName("Arial", SkFontStyle::Bold());
    SkFont font(typeface, 32);
    SkPaint paint;
    paint.setColor(SkColors::kRed);
    canvas->drawString(string, 50, 200, font, paint);
#endif
#endif
    
    // Flush all appended operations on the canvas and commit it to the SkSurface
    canvas->flush();
    
    // Pass the drawable into the Metal Command Buffer and submit it to the GPU
    id<MTLCommandBuffer> commandBuffer([_commandQueue commandBuffer]);
    [commandBuffer presentDrawable:currentDrawable];
    [commandBuffer commit];
    
    // Unlock the Pixel Buffer again so it can be freed up
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  }
};

void SkiaMetalCanvasProvider::setSize(int width, int height) {
  _width = width;
  _height = height;
  _layer.frame = CGRectMake(0, 0, width, height);
  _layer.drawableSize = CGSizeMake(width * getPixelDensity(),
                                   height* getPixelDensity());
}

CALayer* SkiaMetalCanvasProvider::getLayer() { return _layer; }
