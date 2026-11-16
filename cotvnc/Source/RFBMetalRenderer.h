//
//  RFBMetalRenderer.h
//  Chicken
//

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "FrameBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface RFBMetalContext : NSObject

+ (nullable instancetype)sharedContext;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, readonly) id<MTLRenderPipelineState> floatPipelineState;
@property (nonatomic, readonly) id<MTLRenderPipelineState> uintPipelineState;

@end

@interface RFBMetalTextureCache : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)markDirtyRect:(NSRect)fbRect;
- (void)markAllDirty;
- (nullable id<MTLTexture>)updatedTextureForFrameBuffer:(FrameBuffer *)frameBuffer;

@end

@interface RFBMetalRenderer : NSObject

+ (BOOL)renderFrameBuffer:(FrameBuffer *)frameBuffer
                  inLayer:(CAMetalLayer *)metalLayer
               viewBounds:(NSRect)bounds
            monitorOrigin:(NSPoint)monitorOrigin
                     tint:(nullable NSColor *)tint;

@end

NS_ASSUME_NONNULL_END
