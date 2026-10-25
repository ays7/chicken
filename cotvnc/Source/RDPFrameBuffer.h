//
//  RDPFrameBuffer.h
//  Chicken
//
//  Created for Chicken Fork RDP integration.
//

#import "FrameBuffer.h"

@interface RDPFrameBuffer : FrameBuffer
{
    uint8_t *_buffer;
    size_t _stride;
    BOOL _ownsBuffer;
    CGColorSpaceRef _colorSpace;
}

- (id)initWithSize:(NSSize)aSize;
- (void)setSize:(NSSize)aSize;
- (void)setBuffer:(uint8_t *)aBuffer stride:(size_t)aStride;
- (uint8_t *)buffer;
- (size_t)stride;

- (void)drawRect:(NSRect)aRect at:(NSPoint)aPoint;

@end
