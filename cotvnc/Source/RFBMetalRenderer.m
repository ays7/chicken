//
//  RFBMetalRenderer.m
//  Chicken
//

#import "RFBMetalRenderer.h"
#import <simd/simd.h>

typedef struct {
    simd_float2 uvOrigin;
    simd_float2 uvSize;
    simd_float2 textureSize;
    uint32_t pixelFormat;
    uint32_t _padding;
    simd_float4 tintColor;
} RFBUniforms;

static MTLPixelFormat MTLPixelFormatForFrameBufferFormat(FrameBufferMetalPixelFormat format, BOOL *isUintOut)
{
    switch (format) {
        case FrameBufferMetalPixelFormatBGRX8888:
            *isUintOut = NO;
            return MTLPixelFormatBGRA8Unorm;
        case FrameBufferMetalPixelFormatRGBX8888:
        case FrameBufferMetalPixelFormatXBGR8888:
            *isUintOut = NO;
            return MTLPixelFormatRGBA8Unorm;
        case FrameBufferMetalPixelFormatRGB444:
            *isUintOut = YES;
            return MTLPixelFormatR16Uint;
        case FrameBufferMetalPixelFormatRGB222:
            *isUintOut = YES;
            return MTLPixelFormatR8Uint;
        case FrameBufferMetalPixelFormatGray8:
            *isUintOut = NO;
            return MTLPixelFormatR8Unorm;
        case FrameBufferMetalPixelFormatUnsupported:
        default:
            *isUintOut = NO;
            return MTLPixelFormatInvalid;
    }
}

static size_t BytesPerPixelForFrameBufferFormat(FrameBufferMetalPixelFormat format)
{
    switch (format) {
        case FrameBufferMetalPixelFormatBGRX8888:
        case FrameBufferMetalPixelFormatRGBX8888:
        case FrameBufferMetalPixelFormatXBGR8888:
            return 4;
        case FrameBufferMetalPixelFormatRGB444:
            return 2;
        case FrameBufferMetalPixelFormatRGB222:
        case FrameBufferMetalPixelFormatGray8:
            return 1;
        case FrameBufferMetalPixelFormatUnsupported:
        default:
            return 0;
    }
}

static NSString *const kRFBMetalShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct RFBUniforms {\n"
"    float2 uvOrigin;\n"
"    float2 uvSize;\n"
"    float2 textureSize;\n"
"    uint pixelFormat;\n"
"    uint _padding;\n"
"    float4 tintColor;\n"
"};\n"
"\n"
"struct RFBVertexOut {\n"
"    float4 position [[position]];\n"
"    float2 texCoord;\n"
"};\n"
"\n"
"#define kPixelFormatBGRX8888 1u\n"
"#define kPixelFormatRGBX8888 2u\n"
"#define kPixelFormatXBGR8888 3u\n"
"#define kPixelFormatRGB444   4u\n"
"#define kPixelFormatRGB222   5u\n"
"#define kPixelFormatGray8    6u\n"
"\n"
"vertex RFBVertexOut rfbVertexShader(uint vertexID [[vertex_id]],\n"
"                                    constant RFBUniforms &uniforms [[buffer(0)]])\n"
"{\n"
"    const float2 positions[4] = {\n"
"        float2(-1.0, -1.0),\n"
"        float2( 1.0, -1.0),\n"
"        float2(-1.0,  1.0),\n"
"        float2( 1.0,  1.0)\n"
"    };\n"
"    const float2 uvOffsets[4] = {\n"
"        float2(0.0, 1.0),\n"
"        float2(1.0, 1.0),\n"
"        float2(0.0, 0.0),\n"
"        float2(1.0, 0.0)\n"
"    };\n"
"\n"
"    RFBVertexOut out;\n"
"    out.position = float4(positions[vertexID], 0.0, 1.0);\n"
"    out.texCoord = uniforms.uvOrigin + uvOffsets[vertexID] * uniforms.uvSize;\n"
"    return out;\n"
"}\n"
"\n"
"static inline float4 applyTint(float3 rgb, float4 tintColor)\n"
"{\n"
"    float3 blended = mix(rgb, tintColor.rgb, tintColor.a);\n"
"    return float4(blended, 1.0);\n"
"}\n"
"\n"
"fragment float4 rfbFragmentFloat(RFBVertexOut in [[stage_in]],\n"
"                                 constant RFBUniforms &uniforms [[buffer(0)]],\n"
"                                 texture2d<float> tex [[texture(0)]])\n"
"{\n"
"    constexpr sampler nearestSampler(coord::normalized,\n"
"                                     address::clamp_to_edge,\n"
"                                     filter::nearest);\n"
"    float4 sample = tex.sample(nearestSampler, in.texCoord);\n"
"\n"
"    float3 rgb;\n"
"    if (uniforms.pixelFormat == kPixelFormatXBGR8888) {\n"
"        rgb = sample.abg;\n"
"    } else if (uniforms.pixelFormat == kPixelFormatGray8) {\n"
"        rgb = sample.rrr;\n"
"    } else {\n"
"        rgb = sample.rgb;\n"
"    }\n"
"\n"
"    return applyTint(rgb, uniforms.tintColor);\n"
"}\n"
"\n"
"fragment float4 rfbFragmentUint(RFBVertexOut in [[stage_in]],\n"
"                                constant RFBUniforms &uniforms [[buffer(0)]],\n"
"                                texture2d<uint> tex [[texture(0)]])\n"
"{\n"
"    float2 clampedUV = clamp(in.texCoord, float2(0.0), float2(0.999999));\n"
"    uint2 coord = uint2(clampedUV * uniforms.textureSize);\n"
"    uint val = tex.read(coord).r;\n"
"\n"
"    float3 rgb;\n"
"    if (uniforms.pixelFormat == kPixelFormatRGB444) {\n"
"        float r = float((val >> 4) & 0xFu) / 15.0;\n"
"        float g = float(val & 0xFu) / 15.0;\n"
"        float b = float((val >> 12) & 0xFu) / 15.0;\n"
"        rgb = float3(r, g, b);\n"
"    } else {\n"
"        float r = float((val >> 6) & 0x3u) / 3.0;\n"
"        float g = float((val >> 4) & 0x3u) / 3.0;\n"
"        float b = float((val >> 2) & 0x3u) / 3.0;\n"
"        rgb = float3(r, g, b);\n"
"    }\n"
"\n"
"    return applyTint(rgb, uniforms.tintColor);\n"
"}\n";

#pragma mark - RFBMetalContext

@implementation RFBMetalContext

+ (nullable instancetype)sharedContext
{
    static RFBMetalContext *sContext = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            sContext = [[RFBMetalContext alloc] initWithDevice:device];
        }
    });
    return sContext;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (!self)
        return nil;

    _device = device;
    _commandQueue = [device newCommandQueue];
    if (!_commandQueue)
        return nil;

    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (!library) {
        library = [device newLibraryWithSource:kRFBMetalShaderSource options:nil error:&error];
    }
    if (!library) {
        NSLog(@"[RFBMetalContext] Failed to compile Metal shader library: %@", error);
        return nil;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"rfbVertexShader"];
    id<MTLFunction> floatFragFunc = [library newFunctionWithName:@"rfbFragmentFloat"];
    id<MTLFunction> uintFragFunc = [library newFunctionWithName:@"rfbFragmentUint"];
    if (!vertexFunc || !floatFragFunc || !uintFragFunc) {
        NSLog(@"[RFBMetalContext] Failed to load Metal shader functions");
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertexFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    desc.fragmentFunction = floatFragFunc;
    _floatPipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_floatPipelineState) {
        NSLog(@"[RFBMetalContext] Failed to create float pipeline state: %@", error);
        return nil;
    }

    desc.fragmentFunction = uintFragFunc;
    _uintPipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_uintPipelineState) {
        NSLog(@"[RFBMetalContext] Failed to create uint pipeline state: %@", error);
        return nil;
    }

    return self;
}

@end

#pragma mark - RFBMetalTextureCache

@interface RFBMetalTextureCache ()
{
    id<MTLDevice> _device;
    id<MTLTexture> _texture;
    FrameBufferMetalPixelFormat _currentFormat;
    NSRect _dirtyRect;
    BOOL _allDirty;
}
@end

@implementation RFBMetalTextureCache

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self) {
        _device = device;
        _allDirty = YES;
        _dirtyRect = NSZeroRect;
    }
    return self;
}

- (void)markDirtyRect:(NSRect)fbRect
{
    if (_allDirty || fbRect.size.width <= 0 || fbRect.size.height <= 0)
        return;

    if (NSIsEmptyRect(_dirtyRect)) {
        _dirtyRect = fbRect;
    } else {
        _dirtyRect = NSUnionRect(_dirtyRect, fbRect);
    }
}

- (void)markAllDirty
{
    _allDirty = YES;
    _dirtyRect = NSZeroRect;
}

- (nullable id<MTLTexture>)updatedTextureForFrameBuffer:(FrameBuffer *)frameBuffer
{
    [frameBuffer lockPixelBuffer];
    const void *pixels = [frameBuffer pixelBuffer];
    size_t stride = [frameBuffer pixelBufferStride];
    NSSize fbSize = [frameBuffer size];
    FrameBufferMetalPixelFormat fbFormat = [frameBuffer metalPixelFormat];

    if (!pixels || stride == 0 || fbSize.width <= 0 || fbSize.height <= 0) {
        [frameBuffer unlockPixelBuffer];
        return nil;
    }

    BOOL isUint = NO;
    MTLPixelFormat mtlFormat = MTLPixelFormatForFrameBufferFormat(fbFormat, &isUint);
    size_t bpp = BytesPerPixelForFrameBufferFormat(fbFormat);
    if (mtlFormat == MTLPixelFormatInvalid || bpp == 0) {
        [frameBuffer unlockPixelBuffer];
        return nil;
    }

    NSUInteger width = (NSUInteger)fbSize.width;
    NSUInteger height = (NSUInteger)fbSize.height;

    if (!_texture || _texture.width != width || _texture.height != height || _currentFormat != fbFormat) {
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mtlFormat
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead;
        if (@available(macOS 10.15, *)) {
            texDesc.storageMode = [_device hasUnifiedMemory] ? MTLStorageModeShared : MTLStorageModeManaged;
        } else {
            texDesc.storageMode = MTLStorageModeManaged;
        }
        _texture = [_device newTextureWithDescriptor:texDesc];
        _currentFormat = fbFormat;
        _allDirty = YES;
    }

    if (!_texture) {
        [frameBuffer unlockPixelBuffer];
        return nil;
    }

    if (_allDirty) {
        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [_texture replaceRegion:region mipmapLevel:0 withBytes:pixels bytesPerRow:stride];
        _allDirty = NO;
        _dirtyRect = NSZeroRect;
    } else if (!NSIsEmptyRect(_dirtyRect)) {
        NSInteger x0 = MAX((NSInteger)0, (NSInteger)floor(_dirtyRect.origin.x));
        NSInteger y0 = MAX((NSInteger)0, (NSInteger)floor(_dirtyRect.origin.y));
        NSInteger x1 = MIN((NSInteger)width, (NSInteger)ceil(NSMaxX(_dirtyRect)));
        NSInteger y1 = MIN((NSInteger)height, (NSInteger)ceil(NSMaxY(_dirtyRect)));
        if (x1 > x0 && y1 > y0) {
            const uint8_t *src = (const uint8_t *)pixels + (size_t)y0 * stride + (size_t)x0 * bpp;
            MTLRegion region = MTLRegionMake2D((NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0));
            [_texture replaceRegion:region mipmapLevel:0 withBytes:src bytesPerRow:stride];
        }
        _dirtyRect = NSZeroRect;
    }

    [frameBuffer unlockPixelBuffer];
    return _texture;
}

@end

#pragma mark - RFBMetalRenderer

@implementation RFBMetalRenderer

+ (BOOL)renderFrameBuffer:(FrameBuffer *)frameBuffer
                  inLayer:(CAMetalLayer *)metalLayer
               viewBounds:(NSRect)bounds
            monitorOrigin:(NSPoint)monitorOrigin
             displayScale:(CGFloat)displayScale
                     tint:(nullable NSColor *)tint
{
    RFBMetalContext *ctx = [RFBMetalContext sharedContext];
    if (!ctx || !frameBuffer || !metalLayer)
        return NO;

    RFBMetalTextureCache *cache = [frameBuffer metalTextureCache];
    if (!cache) {
        cache = [[RFBMetalTextureCache alloc] initWithDevice:ctx.device];
        [frameBuffer setMetalTextureCache:cache];
    }

    id<MTLTexture> texture = [cache updatedTextureForFrameBuffer:frameBuffer];
    if (!texture)
        return NO;

    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable)
        return NO;

    id<MTLCommandBuffer> commandBuffer = [ctx.commandQueue commandBuffer];
    if (!commandBuffer)
        return NO;

    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    if (!encoder)
        return NO;

    FrameBufferMetalPixelFormat fbFormat = [frameBuffer metalPixelFormat];
    BOOL isUint = NO;
    MTLPixelFormatForFrameBufferFormat(fbFormat, &isUint);
    id<MTLRenderPipelineState> pipeline = isUint ? ctx.uintPipelineState : ctx.floatPipelineState;

    float texW = (float)texture.width;
    float texH = (float)texture.height;
    CGFloat effectiveScale = displayScale > 0.0 ? displayScale : ([frameBuffer displayScale] > 0.0 ? [frameBuffer displayScale] : 1.0);

    RFBUniforms uniforms;
    uniforms.uvOrigin = simd_make_float2((float)monitorOrigin.x / texW, (float)monitorOrigin.y / texH);
    uniforms.uvSize = simd_make_float2((float)(bounds.size.width * effectiveScale) / texW,
                                       (float)(bounds.size.height * effectiveScale) / texH);
    uniforms.textureSize = simd_make_float2(texW, texH);
    uniforms.pixelFormat = (uint32_t)fbFormat;
    uniforms._padding = 0;

    if (tint && [tint alphaComponent] > 0.0) {
        NSColor *srgbTint = [tint colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (srgbTint) {
            uniforms.tintColor = simd_make_float4((float)[srgbTint redComponent],
                                                  (float)[srgbTint greenComponent],
                                                  (float)[srgbTint blueComponent],
                                                  (float)[srgbTint alphaComponent]);
        } else {
            uniforms.tintColor = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);
        }
    } else {
        uniforms.tintColor = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);
    }

    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

@end
