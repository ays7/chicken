/* Copyright (C) 1998-2000  Helmut Maierhofer <helmut.maierhofer@chello.at>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 */

#import "RFBView.h"
#import "EventFilter.h"
#import "RFBConnection.h"
#import "FrameBuffer.h"
#import "Profile.h"
#import "RFBMetalRenderer.h"
//#import "RectangleList.h"

#if MAC_OS_X_VERSION_MAX_ALLOWED < 1050
#if __LP64__
typedef long NSInteger;
#else
typedef int NSInteger;
#endif
#endif

@interface FrameBuffer (MonitorOffset)
- (void)drawRect:(NSRect)aRect at:(NSPoint)aPoint monitorOrigin:(NSPoint)origin viewHeight:(CGFloat)viewHeight;
@end

@implementation RFBView

- (void)_commonMetalInit
{
    if ([RFBMetalContext sharedContext] != nil) {
        _useMetal = YES;
        [self setWantsLayer:YES];
        [self setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawDuringViewResize];
    }
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _commonMetalInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self _commonMetalInit];
    }
    return self;
}

- (BOOL)wantsUpdateLayer
{
    return _useMetal;
}

- (CALayer *)makeBackingLayer
{
    if (!_useMetal) {
        return [super makeBackingLayer];
    }
    RFBMetalContext *ctx = [RFBMetalContext sharedContext];
    CAMetalLayer *metalLayer = [CAMetalLayer layer];
    metalLayer.device = ctx.device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = YES;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (srgb) {
        metalLayer.colorspace = srgb;
        CGColorSpaceRelease(srgb);
    }
    metalLayer.delegate = self;
    return metalLayer;
}

- (void)_updateMetalDrawableSize
{
    if (!_useMetal || ![self.layer isKindOfClass:[CAMetalLayer class]])
        return;

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
    if (scale <= 0.0)
        scale = 1.0;
    metalLayer.contentsScale = scale;

    NSSize b = [self bounds].size;
    if (b.width > 0 && b.height > 0) {
        metalLayer.drawableSize = CGSizeMake(floor(b.width * scale), floor(b.height * scale));
    }
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self _updateMetalDrawableSize];
    if (_useMetal) {
        [self.layer setNeedsDisplay];
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self _updateMetalDrawableSize];
    if (_useMetal) {
        [self.layer setNeedsDisplay];
    }
}

/* One-time initializer to read the cursors into memory. */
+ (NSCursor *)_cursorForName: (NSString *)name
{
	static NSDictionary *sMapping = nil;
	if ( ! sMapping )
	{
		NSBundle *mainBundle = [NSBundle mainBundle];
		NSDictionary *entries = [NSDictionary dictionaryWithContentsOfFile: [mainBundle pathForResource: @"cursors" ofType: @"plist"]];
		NSParameterAssert( entries != nil );
		sMapping = [[NSMutableDictionary alloc] init];
		NSEnumerator *cursorNameEnumerator = [entries keyEnumerator];
		NSDictionary *cursorName;
		
		while ( cursorName = [cursorNameEnumerator nextObject] )
		{
			NSDictionary *cursorEntry = [entries objectForKey: cursorName];
			NSString *localPath = [cursorEntry objectForKey: @"localPath"];
			NSString *path = [mainBundle pathForResource: localPath ofType: nil];
			NSImage *image = [[NSImage alloc] initWithContentsOfFile: path];
			
			int hotspotX = [[cursorEntry objectForKey: @"hotspotX"] intValue];
			int hotspotY = [[cursorEntry objectForKey: @"hotspotY"] intValue];
			NSPoint hotspot = {hotspotX, hotspotY};
			
			NSCursor *cursor = [[NSCursor alloc] initWithImage: image hotSpot: hotspot];
			[(NSMutableDictionary *)sMapping setObject: cursor forKey: cursorName];
		}
	}
	
	return [sMapping objectForKey: name];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
    if (_delegate && [_delegate respondsToSelector:@selector(viewOnly)] && [_delegate viewOnly])
    {
        return NO;
    }
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (CGFloat)_effectiveDisplayScale
{
    if (_displayScale > 0.0)
        return _displayScale;
    if (fbuf && [fbuf displayScale] > 0.0)
        return [fbuf displayScale];
    return 1.0;
}

- (CGFloat)displayScale
{
    return [self _effectiveDisplayScale];
}

- (void)setDisplayScale:(CGFloat)scale
{
    _displayScale = scale;
    if (_useMetal) {
        [self.layer setNeedsDisplay];
    } else {
        [self setNeedsDisplay:YES];
    }
}

- (void)setFrameBuffer:(id)aBuffer;
{
    NSRect f = [self frame];
    
    fbuf = aBuffer;
    CGFloat fbScale = [self _effectiveDisplayScale];
    NSSize fbSize = [fbuf size];
    f.size = NSMakeSize(fbSize.width / fbScale, fbSize.height / fbScale);
    [self setFrame:f];
    if (_useMetal && fbuf) {
        RFBMetalTextureCache *cache = [fbuf metalTextureCache];
        if (!cache) {
            cache = [[RFBMetalTextureCache alloc] initWithDevice:[RFBMetalContext sharedContext].device];
            [fbuf setMetalTextureCache:cache];
        }
        [cache markAllDirty];
        [self.layer setNeedsDisplay];
    }
}

- (void)dealloc
{
    if (_cursorTrackingArea)
    {
        [self removeTrackingArea:_cursorTrackingArea];
        _cursorTrackingArea = nil;
    }
    if (_delegate)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:_delegate name:NSViewFrameDidChangeNotification object:self];
        _delegate = nil;
    }
    _eventFilter = nil;
    fbuf = nil;
    _serverCursor = nil;
    _modifierCursor = nil;
    tint = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_cursorTrackingArea)
    {
        [self removeTrackingArea:_cursorTrackingArea];
        _cursorTrackingArea = nil;
    }
    _cursorTrackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                       options:(NSTrackingCursorUpdate |
                                                                NSTrackingMouseMoved |
                                                                NSTrackingMouseEnteredAndExited |
                                                                NSTrackingActiveInActiveApp |
                                                                NSTrackingInVisibleRect)
                                                         owner:self
                                                      userInfo:nil];
    [self addTrackingArea:_cursorTrackingArea];
}

- (void)cursorUpdate:(NSEvent *)theEvent
{
    if (_modifierCursor)
        [_modifierCursor set];
    else if (_serverCursor)
        [_serverCursor set];
    else
        [[[self class] _cursorForName:@"rfbCursor"] set];
}

- (void)setCursorTo: (NSString *)name
{
	if (name == nil)
        _modifierCursor = nil;
    else
        _modifierCursor = [[self class] _cursorForName: name];

    if (_modifierCursor)
        [_modifierCursor set];
    else if (_serverCursor)
        [_serverCursor set];
    else
        [[[self class] _cursorForName:@"rfbCursor"] set];
}

- (void)setServerCursorTo: (NSCursor *)aCursor
{
    if (_serverCursor == aCursor)
        return;

    _serverCursor = aCursor;
    if (!_modifierCursor) {
        [[self window] invalidateCursorRectsForView: self];
        if (aCursor)
            [aCursor set];
        else
            [[NSCursor arrowCursor] set];
    }
}

- (void)setTint: (NSColor *)aTint
{
    if (![tint isEqual:aTint]) {
        tint = aTint;
        drawTint = [tint alphaComponent] != 0.0;
        [self setNeedsDisplay:YES];
    }
}

- (void)setDelegate:(id<RemoteConnection>)delegate
{
    if (_delegate)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:_delegate name:NSViewFrameDidChangeNotification object:self];
    }
    _delegate = delegate;
    if (_delegate)
    {
        _eventFilter = [_delegate eventFilter];
        [self setCursorTo: nil];
        [self setPostsFrameChangedNotifications: YES];
        [[NSNotificationCenter defaultCenter] addObserver: _delegate selector: @selector(viewFrameDidChange:) name: NSViewFrameDidChangeNotification object: self];
    }
    else
    {
        _eventFilter = nil;
    }
}

- (id<RemoteConnection>)delegate
{
	return _delegate;
}

- (NSPoint)monitorOrigin
{
    return _monitorOrigin;
}

- (void)setMonitorOrigin:(NSPoint)origin
{
    _monitorOrigin = origin;
    if (_useMetal) {
        [self.layer setNeedsDisplay];
    }
}

- (void)setNeedsDisplay:(BOOL)needsDisplay
{
    if (_useMetal) {
        if (needsDisplay && fbuf) {
            RFBMetalTextureCache *cache = [fbuf metalTextureCache];
            if (!cache) {
                cache = [[RFBMetalTextureCache alloc] initWithDevice:[RFBMetalContext sharedContext].device];
                [fbuf setMetalTextureCache:cache];
            }
            [cache markAllDirty];
            [self.layer setNeedsDisplay];
        }
        return;
    }
    [super setNeedsDisplay:needsDisplay];
}

- (void)setNeedsDisplayInRect:(NSRect)invalidRect
{
    if (_useMetal) {
        if (fbuf && invalidRect.size.width > 0 && invalidRect.size.height > 0) {
            RFBMetalTextureCache *cache = [fbuf metalTextureCache];
            if (!cache) {
                cache = [[RFBMetalTextureCache alloc] initWithDevice:[RFBMetalContext sharedContext].device];
                [fbuf setMetalTextureCache:cache];
            }
            NSRect b = [self bounds];
            CGFloat fbScale = [self _effectiveDisplayScale];
            NSRect fbRect;
            fbRect.origin.x = invalidRect.origin.x * fbScale + _monitorOrigin.x;
            fbRect.origin.y = (b.size.height - NSMaxY(invalidRect)) * fbScale + _monitorOrigin.y;
            fbRect.size = NSMakeSize(invalidRect.size.width * fbScale, invalidRect.size.height * fbScale);
            [cache markDirtyRect:fbRect];
            [self.layer setNeedsDisplay];
        }
        return;
    }
    [super setNeedsDisplayInRect:invalidRect];
}

- (void)displayIfNeededIgnoringOpacity
{
    if (_useMetal) {
        [self.layer displayIfNeeded];
        return;
    }
    [super displayIfNeededIgnoringOpacity];
}

- (void)displayLayer:(CALayer *)layer
{
    if (!_useMetal || !fbuf || ![layer isKindOfClass:[CAMetalLayer class]])
        return;

    [self _updateMetalDrawableSize];
    [RFBMetalRenderer renderFrameBuffer:fbuf
                                inLayer:(CAMetalLayer *)layer
                             viewBounds:[self bounds]
                          monitorOrigin:_monitorOrigin
                           displayScale:[self _effectiveDisplayScale]
                                   tint:(drawTint ? tint : nil)];
}

- (void)drawRect:(NSRect)destRect
{
    if (!fbuf)
        return;

    NSRect          b = [self bounds];
    const NSRect    *rects = NULL;
    NSInteger       numRects = 0;
    NSInteger       i;

    /* We always draw the framebuffer at scale. However, on a "Retina" display,
     * there are 4 pixels for each point. By default, the OS will interpolate
     * for us, but we don't want that. We want to draw "large" pixels. */
    [[NSGraphicsContext currentContext]
        setImageInterpolation:NSImageInterpolationNone];

    if (drawTint)
        [tint setFill];

    BOOL supportsMonitorOffset = [fbuf respondsToSelector:@selector(drawRect:at:monitorOrigin:viewHeight:)];

    [self getRectsBeingDrawn:&rects count:&numRects];
    if (rects && numRects > 0) {
        for (i = 0; i < numRects; i++) {
            NSRect      r = rects[i];
            r.origin.y = b.size.height - NSMaxY(r);
            if (supportsMonitorOffset) {
                [(id)fbuf drawRect:r at:rects[i].origin monitorOrigin:_monitorOrigin viewHeight:b.size.height];
            } else {
                [fbuf drawRect:r at:rects[i].origin];
            }
            if (drawTint)
                NSRectFillUsingOperation(rects[i], NSCompositingOperationSourceOver);
        }
    } else {
        NSRect r = destRect;
        r.origin.y = b.size.height - NSMaxY(r);
        if (supportsMonitorOffset) {
            [(id)fbuf drawRect:r at:destRect.origin monitorOrigin:_monitorOrigin viewHeight:b.size.height];
        } else {
            [fbuf drawRect:r at:destRect.origin];
        }
        if (drawTint)
            NSRectFillUsingOperation(destRect, NSCompositingOperationSourceOver);
    }
}

/* Called by system to set-up cursors for this view */
- (void)resetCursorRects
{
    if (!_delegate || [_delegate viewOnly])
        return;

    NSRect cursorRect = [self visibleRect];
    if (NSIsEmptyRect(cursorRect))
        return;

    if (_modifierCursor)
        [self addCursorRect: cursorRect cursor: _modifierCursor];
    else if (_serverCursor)
        [self addCursorRect: cursorRect cursor: _serverCursor];
    else
        [self addCursorRect: cursorRect cursor: [[self class] _cursorForName: @"rfbCursor"]];
}

- (void)mouseDown:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter mouseDown: theEvent];  }

- (void)rightMouseDown:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter rightMouseDown: theEvent];  }

- (void)otherMouseDown:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter otherMouseDown: theEvent];  }

- (void)mouseUp:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter mouseUp: theEvent];  }

- (void)rightMouseUp:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter rightMouseUp: theEvent];  }

- (void)otherMouseUp:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter otherMouseUp: theEvent];  }

- (void)mouseEntered:(NSEvent *)theEvent
{  [[self window] setAcceptsMouseMovedEvents: YES];  }

- (void)mouseExited:(NSEvent *)theEvent
{
}

- (void)mouseMoved:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter mouseMoved: theEvent];  }

- (void)mouseDragged:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter mouseDragged: theEvent];}

- (void)rightMouseDragged:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter rightMouseDragged: theEvent];  }

- (void)otherMouseDragged:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter otherMouseDragged: theEvent];  }

- (void)scrollWheel:(NSEvent *)theEvent
{  [_eventFilter setView:self]; [_eventFilter scrollWheel: theEvent];  }

- (void)keyDown:(NSEvent *)theEvent
{  [_eventFilter keyDown: theEvent];  }

- (void)keyUp:(NSEvent *)theEvent
{  [_eventFilter keyUp: theEvent];  }

- (void)flagsChanged:(NSEvent *)theEvent
{  [_eventFilter flagsChanged: theEvent];  }


- (void)concludeDragOperation:(id <NSDraggingInfo>)sender {}

- (unsigned int)draggingEntered:(id <NSDraggingInfo>)sender
{
    return NSDragOperationGeneric;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender {}

- (unsigned int)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return NSDragOperationGeneric;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    return [_delegate pasteFromPasteboard:[sender draggingPasteboard]];
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
    return YES;
}

@end
