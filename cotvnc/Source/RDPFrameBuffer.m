//
//  RDPFrameBuffer.m
//  Chicken
//
//  Created for Chicken Fork RDP integration.
//

#import "RDPFrameBuffer.h"

@implementation RDPFrameBuffer

- (id)initWithSize:(NSSize)aSize
{
    rfbPixelFormat pf;
    memset(&pf, 0, sizeof(pf));
    pf.bitsPerPixel = 32;
    pf.depth = 24;
    pf.redMax = pf.greenMax = pf.blueMax = 255;
    pf.redShift = 16;
    pf.greenShift = 8;
    pf.blueShift = 0;
    pf.trueColour = 1;

    if ((self = [super initWithSize:aSize andFormat:&pf]))
    {
        size = aSize;
        bytesPerPixel = 4;
        samplesPerPixel = 3;
        bitsPerColor = 8;
        maxValue = 255;
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _stride = (size_t)aSize.width * 4;
        _buffer = (uint8_t *)calloc((size_t)aSize.height, _stride);
        _ownsBuffer = YES;
    }
    return self;
}

- (void)dealloc
{
    if (_ownsBuffer && _buffer)
    {
        free(_buffer);
        _buffer = NULL;
    }
    if (_colorSpace)
    {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    [super dealloc];
}

- (void)setSize:(NSSize)aSize
{
    if (NSEqualSizes(size, aSize))
        return;

    size = aSize;
    if (_ownsBuffer)
    {
        if (_buffer)
            free(_buffer);
        _stride = (size_t)aSize.width * 4;
        _buffer = (uint8_t *)calloc((size_t)aSize.height, _stride);
    }
}

- (void)setBuffer:(uint8_t *)aBuffer stride:(size_t)aStride
{
    if (_ownsBuffer && _buffer)
    {
        free(_buffer);
        _ownsBuffer = NO;
    }
    _buffer = aBuffer;
    _stride = aStride;
}

- (uint8_t *)buffer
{
    return _buffer;
}

- (size_t)stride
{
    return _stride;
}

- (NSSize)size
{
    return size;
}

- (unsigned int)bytesPerPixel
{
    return 4;
}

- (void)drawRect:(NSRect)aRect at:(NSPoint)aPoint
{
    if (!_buffer || size.width <= 0 || size.height <= 0 || _stride <= 0)
        return;

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx)
        return;

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, _buffer, _stride * (size_t)size.height, NULL);
    if (!provider)
        return;

    CGImageRef image = CGImageCreate((size_t)size.width,
                                     (size_t)size.height,
                                     8,
                                     32,
                                     _stride,
                                     _colorSpace,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                     provider,
                                     NULL,
                                     NO,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image)
        return;

    CGContextSaveGState(ctx);
    if (aRect.size.width > 0 && aRect.size.height > 0)
    {
        CGContextClipToRect(ctx, CGRectMake(aPoint.x, aPoint.y, aRect.size.width, aRect.size.height));
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, size.width, size.height), image);
    CGContextRestoreGState(ctx);

    CGImageRelease(image);
}

@end
