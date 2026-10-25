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
//#import "RectangleList.h"

#if MAC_OS_X_VERSION_MAX_ALLOWED < 1050
#if __LP64__
typedef long NSInteger;
#else
typedef int NSInteger;
#endif
#endif

@implementation RFBView

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
            [cursor release];
            [image release];
		}
	}
	
	return [sMapping objectForKey: name];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
    return NO;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)setFrameBuffer:(id)aBuffer;
{
    NSRect f = [self frame];
    
    [fbuf release];
    fbuf = [aBuffer retain];
    f.size = [aBuffer size];
    [self setFrame:f];
}

- (void)dealloc
{
    if (_delegate)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:_delegate name:NSViewFrameDidChangeNotification object:self];
        _delegate = nil;
    }
    _eventFilter = nil;
    [fbuf release];
    fbuf = nil;
    [_serverCursor release];
    _serverCursor = nil;
    [_modifierCursor release];
    _modifierCursor = nil;
    [tint release];
    tint = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)setCursorTo: (NSString *)name
{
    [_modifierCursor release];
	if (name == nil)
        _modifierCursor = nil;
    else
        _modifierCursor = [[[self class] _cursorForName: name] retain];
    [[self window] invalidateCursorRectsForView: self];
}

- (void)setServerCursorTo: (NSCursor *)aCursor
{
    [_serverCursor release];
    _serverCursor = [aCursor retain];
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
        [tint release];
        tint = [aTint retain];
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

    [self getRectsBeingDrawn:&rects count:&numRects];
    if (rects && numRects > 0) {
        for (i = 0; i < numRects; i++) {
            NSRect      r = rects[i];
            r.origin.y = b.size.height - NSMaxY(r);
            [fbuf drawRect:r at:rects[i].origin];
            if (drawTint)
                NSRectFillUsingOperation(rects[i], NSCompositingOperationSourceOver);
        }
    } else {
        NSRect r = destRect;
        r.origin.y = b.size.height - NSMaxY(r);
        [fbuf drawRect:r at:destRect.origin];
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
{  [_eventFilter mouseDown: theEvent];  }

- (void)rightMouseDown:(NSEvent *)theEvent
{  [_eventFilter rightMouseDown: theEvent];  }

- (void)otherMouseDown:(NSEvent *)theEvent
{  [_eventFilter otherMouseDown: theEvent];  }

- (void)mouseUp:(NSEvent *)theEvent
{  [_eventFilter mouseUp: theEvent];  }

- (void)rightMouseUp:(NSEvent *)theEvent
{  [_eventFilter rightMouseUp: theEvent];  }

- (void)otherMouseUp:(NSEvent *)theEvent
{  [_eventFilter otherMouseUp: theEvent];  }

- (void)mouseEntered:(NSEvent *)theEvent
{  [[self window] setAcceptsMouseMovedEvents: YES];  }

- (void)mouseExited:(NSEvent *)theEvent
{  [[self window] setAcceptsMouseMovedEvents: NO];  }

- (void)mouseMoved:(NSEvent *)theEvent
{  [_eventFilter mouseMoved: theEvent];  }

- (void)mouseDragged:(NSEvent *)theEvent
{  [_eventFilter mouseDragged: theEvent];}

- (void)rightMouseDragged:(NSEvent *)theEvent
{  [_eventFilter rightMouseDragged: theEvent];  }

- (void)otherMouseDragged:(NSEvent *)theEvent
{  [_eventFilter otherMouseDragged: theEvent];  }

- (void)scrollWheel:(NSEvent *)theEvent
{  [_eventFilter scrollWheel: theEvent];  }

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
