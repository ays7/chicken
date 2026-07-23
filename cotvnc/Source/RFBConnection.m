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

#import "RFBConnection.h"
#import <zlib.h>
#import "AppDelegate.h"
#import "ByteBlockReader.h"
#import "ConnectionWaiter.h"
#import "debug.h"
#import "EncodingReader.h"
#import "EventFilter.h"
#import "FrameBuffer.h"
#import "FrameBufferUpdateReader.h"

#import "IServerData.h"
#import "KeyEquivalent.h"
#import "KeyEquivalentManager.h"
#import "KeyEquivalentScenario.h"
#import "Keymap.h"
#import "PersistentServer.h"
#import "PrefController.h"
#import "Profile.h"
#import "ProfileManager.h"
#import "RFBConnectionManager.h"
#import "RFBHandshaker.h"
#import "RFBProtocol.h"
#import "RFBServerInitReader.h"
#import "RFBView.h"
#import "Session.h"
#import "SshTunnel.h"
#define XK_MISCELLANY
#include "keysymdef.h"
#include <libc.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>

// size of write buffer
#define BUFFER_SIZE 2048
#define READ_BUF_SIZE (1024*1024)

@interface RFBConnection (Private)

- (void)sendStringToServersClipboard:(const char *)cStr length:(unsigned)len;

@end

@implementation RFBConnection

// jason added for Jaguar check
+ (void)initialize {
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithFloat: 0.0], @"FrameBufferUpdateSeconds", nil];
	
	[standardUserDefaults registerDefaults: dict];
}

- (id)initWithFileHandle:(NSFileHandle*)file server:(id<IServerData>)server
{
    if (self = [super init]) {
        ByteBlockReader *versionReader;

        _profile = [[server profile] retain];

        currentReader = nil;

        server_ = [(id)server retain];
        password = [[server password] retain];
        
        _eventFilter = [[EventFilter alloc] init];
        [_eventFilter setConnection: self];

        versionReader = [[ByteBlockReader alloc] initTarget:self action:@selector(setServerVersion:)];
        [versionReader setBufferSize: 12];
        [self setReader:versionReader];
        [versionReader release];

        socketHandler = [file retain];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(readData:) 	name:NSFileHandleDataAvailableNotification object:socketHandler];
        [socketHandler waitForDataInBackgroundAndNotify];

        serverSupportsExtendedClipboard = NO;
        serverClipboardFlags = 0;

        lastMouseX = -1;
        lastMouseY = -1;
        lastMouseMovement = [[NSDate alloc] init];

        _mouseMovedTrackingTag = 0;
        _lastUpdateRequestDate = nil;

        isReceivingUpdate = NO;
        bytesReceived = 0;

        lastDesktopSizeSent = NSZeroSize;
        lastDesktopSizeTime = nil;

        int     keepAliveTime = 5 * 60; // 5 minutes
        if (setsockopt([socketHandler fileDescriptor], IPPROTO_TCP,
                    TCP_KEEPALIVE, (char *)&keepAliveTime, sizeof(int)) < 0)
            NSLog(@"Error with setsockopt TCP_KEEPALIVE: %d", errno);

#if 1
        int     nodelay = 1;
        if (setsockopt([socketHandler fileDescriptor], IPPROTO_TCP, TCP_NODELAY,
                        (char *)&nodelay, sizeof(int)) < 0)
            NSLog(@"Error with setsockopt TCP_NODELAY: %d", errno);
#endif

        if (fcntl([socketHandler fileDescriptor], F_SETFL, O_NONBLOCK) == -1) {
            NSLog(@"Error setting non-blocking I/O: %d", errno);
            // :TODO: should bail here
        }

        writeBuffer = (unsigned char *)malloc(BUFFER_SIZE);
        bufferLen = 0;
        lastBufferedIsMouseMovement = NO;
	}
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_frameUpdateTimer release];
    [socketHandler closeFile]; // release is not sufficient because the
                               // asynchronous reading seems to keep a retain
	[socketHandler release];
    [sshTunnel release];
    [currentReader release];
	[_eventFilter release];
	[handshaker release];
    [server_ release];
    [password release];
    [username release];
	[rfbProtocol release];
	[frameBuffer release];
    [lastMouseMovement release];
    [_lastUpdateRequestDate release];
    [lastDesktopSizeTime release];
    free(writeBuffer);

    [super dealloc];
}

- (void)closeConnection
{
    [_frameUpdateTimer invalidate];
    [_frameUpdateTimer release];
    _frameUpdateTimer = nil;
    [self removeMouseMovedTrackingRect];
    [rfbView setDelegate:nil];
    rfbView = nil;
    session = nil;
}

- (void)setRfbView:(RFBView *)view
{
    rfbView = view;
	[_eventFilter setView: rfbView];
    if (frameBuffer)
        [rfbView setFrameBuffer:frameBuffer];
}

- (void)setSession:(Session *)aSession
{
    session = aSession;
}

- (void)setPassword:(NSString *)aPassword
{
    [password release];
    password = [aPassword retain];
    
    [handshaker gotPassword];
}

- (void)setUsername:(NSString *)aUsername
{
    [username release];
    username = [aUsername retain];
}

- (NSString *)username
{
    return username;
}

- (void)promptForUsernameAndPassword
{
    [session promptForUsernameAndPassword];
}

- (void)setSshTunnel:(SshTunnel *)tunnel
{
    [sshTunnel autorelease];
    sshTunnel = [tunnel retain];
}

- (id<IServerData>)server
{
    return server_;
}

- (Profile*)profile
{
    return _profile;
}

- (int) protocolMajorVersion {
	return MIN(rfbProtocolMajorVersion, serverMajorVersion);
}

- (int) protocolMinorVersion {
    if (serverMajorVersion > rfbProtocolMajorVersion)
        return rfbProtocolMinorVersion;
    else
        return MIN(rfbProtocolMinorVersion, serverMinorVersion);
}

- (void)setReader:(ByteReader*)aReader
{
    [currentReader release];
    currentReader = [aReader retain];
    [aReader resetReader];
}

- (void)setServerVersion:(NSData*)aVersion
{
        // C-string version of server versions: 12 bytes + NULL
    char    cStr[13];

    [aVersion getBytes: cStr length: 12];
    cStr[12] = '\0';
	if (sscanf(cStr, rfbProtocolVersionFormat, &serverMajorVersion, &serverMinorVersion) < 2) {
        [session terminateConnection: NSLocalizedString(@"NotVNC", nil)];
        return;
    }
	
    // ARD sends 889 version#, force 3.8 to match modern macOS Screen Sharing & RoyalVNCKit
	if (serverMinorVersion == 889) {
		serverMinorVersion = 8;
	}
	
	// Detect SetDesktopSize support (RFB 3.8+)
	_serverSupportsSetDesktopSize = (serverMajorVersion > 3 || (serverMajorVersion == 3 && serverMinorVersion >= 8));
	if (isAppleServer) {
		_serverSupportsSetDesktopSize = NO;
	}
	
    handshaker = [[RFBHandshaker alloc] initWithConnection: self];
	[handshaker handshake];
}

- (void)setCursor: (NSCursor *)aCursor
{
    if (![server_ viewOnly])
        [rfbView setServerCursorTo: aCursor];
}

- (BOOL)serverSupportsSetDesktopSize
{
    if (isAppleServer) {
        return NO;
    }
    return _serverSupportsSetDesktopSize;
}

- (void)terminateConnection:(NSString *)reason
{
    [self setReader:nil]; // causes readData to stop
    [session terminateConnection:reason];
}

- (void)authenticationFailed:(NSString *)reason
{
    [session authenticationFailed:reason];
}

- (void)promptForPassword
{
    [session promptForPassword];
}

/* Creates a framebuffer and sets up rfbView for a given display size */
- (void)sizeDisplay:(NSSize)aSize withPixelFormat:(rfbPixelFormat *)pixf
{
    id frameBufferClass;

	[frameBuffer release];
    frameBufferClass = [[PrefController sharedController] defaultFrameBufferClass];
    frameBuffer = [[frameBufferClass alloc] initWithSize:aSize andFormat:pixf];
	[frameBuffer setServerMajorVersion: serverMajorVersion minorVersion: serverMinorVersion];
	
    [rfbView setFrameBuffer:frameBuffer];
}

- (void)setDisplayName:(NSString*)aName
{
    [session setDisplayName:aName];
}

/* Handshaking has been completed */
- (void)start:(ServerInitMessage*)info
{
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection start: Starting RFB session post-handshake...");
    [rfbProtocol release];
    rfbProtocol = [[RFBProtocol alloc] initWithConnection:self serverInfo:info];

    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection start: Display size (%d x %d)", [info size].width, [info size].height);
    [self sizeDisplay:[info size] withPixelFormat:[info pixelFormatData]];
    [session setSize:[info size]];
    [rfbView setFrameBuffer:frameBuffer];
    [rfbView setDelegate:self];
    [session setupWindow];
    [session setDisplayName: [info name]];
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection start: Requesting initial non-incremental update...");
    [self requestUpdate:[rfbView bounds] incremental:NO];
    [rfbProtocol setFrameBuffer:frameBuffer];

    [handshaker release];
    handshaker = nil;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection start: Handshaker released.");
}

- (NSString*)password
{
    return password;
}

- (BOOL)connectShared
{
    return [server_ shared];
}

- (BOOL)viewOnly
{
	return [server_ viewOnly];
}

- (void)invalidateRect:(NSRect)aRect
{
    NSRect b = [rfbView bounds];
    NSRect r = aRect;

    r.origin.y = b.size.height - NSMaxY(r);
    [rfbView setNeedsDisplayInRect: r];
}

- (void)frameBufferUpdateBeginning
{
    isReceivingUpdate = YES;
}

- (void)frameBufferUpdateComplete {
	if (! _hasManualFrameBufferUpdates)
		[self queueUpdateRequest];
    [self writeBuffer]; // flush buffered mouse movement, if any
    [rfbView displayIfNeededIgnoringOpacity];
    [session frameBufferUpdateComplete];
    isReceivingUpdate = NO;
}

/* End of a framebuffer update which included a resize. We enact the resize
 * here. */
- (void)frameBufferUpdateCompleteWithResize:(NSSize)newSize
{
    [self sizeDisplay:newSize withPixelFormat:[frameBuffer pixelFormat]];
    [rfbProtocol setFrameBuffer:frameBuffer];
    [self requestUpdate:[rfbView bounds] incremental:NO];
    isReceivingUpdate = NO;
    [session frameBufferUpdateComplete];

    // Only resize the session window if server doesn't support SetDesktopSize
    // or connection is view-only.
    // Otherwise window resizing is driven by user actions.
    if (!_serverSupportsSetDesktopSize || [self viewOnly]) {
        [session resize:newSize];
    }
}

- (void)readData:(NSNotification*)aNotification
{
    unsigned char   *buf = malloc(READ_BUF_SIZE);
	NSAutoreleasePool *pool;
    NSDate          *startTime = [NSDate date];

    [[self retain] autorelease];
    pool = [[NSAutoreleasePool alloc] init]; // if we process slower than our requests, we don't autorelease until we get a break, which could be never.

    do {
        unsigned char   *bytes = buf;
        unsigned        consumed;
        ssize_t         length;

        length = read([socketHandler fileDescriptor], buf, READ_BUF_SIZE);

        if (length == -1 && errno == EAGAIN)
            break; // no data

        if(length <= 0) {	// server closed socket
            DiagnosticLog(DiagnosticLogLevelBasic, @"Socket read returned %ld (errno %d: %s). Server closed socket during reader: %@", (long)length, errno, strerror(errno), NSStringFromClass([currentReader class]));
            NSString *reason = NSLocalizedString( @"ServerClosed", nil );
            [self terminateConnection:reason];
            [pool release];
            free(buf);
            return;
        }

        if (IsDiagnosticLoggingEnabled(DiagnosticLogLevelVerbose)) {
            NSMutableString *hexStr = [NSMutableString string];
            NSUInteger dumpLen = length < 32 ? (NSUInteger)length : 32;
            for (NSUInteger i = 0; i < dumpLen; i++) {
                [hexStr appendFormat:@"%02X ", bytes[i]];
            }
            if (length > 32) [hexStr appendString:@"..."];
            DiagnosticLog(DiagnosticLogLevelVerbose, @"Socket read received %ld bytes during reader %@: %@", (long)length, NSStringFromClass([currentReader class]), hexStr);
        }
        
        while(length) {
            consumed = [currentReader readBytes:bytes length:length];

            if (consumed == 0) {
                DiagnosticLog(DiagnosticLogLevelBasic, @"Reader %@ consumed 0 bytes of %ld bytes remaining. Protocol error terminating connection.", NSStringFromClass([currentReader class]), (long)length);
                [self terminateConnection: NSLocalizedString(@"ProtocolError", nil)];
                [pool release];
                return;
            }

            length -= consumed;
            bytes += consumed;
            if (isReceivingUpdate)
                bytesReceived += consumed;
            if (currentReader == nil) {
                [pool release];
                free(buf);
                return;
            }
        }
    } while (-[startTime timeIntervalSinceNow] < 0.05);

    [socketHandler waitForDataInBackgroundAndNotify];
	[pool release];
    free(buf);
}

/* Request frame buffer update, possibly after a delay */
- (void)queueUpdateRequest {
    if (_frameBufferUpdateSeconds > 0.0) {
        if (_frameUpdateTimer == nil) {
            _frameUpdateTimer = [[NSTimer scheduledTimerWithTimeInterval: _frameBufferUpdateSeconds target: self selector: @selector(requestFrameBufferUpdate:) userInfo: nil repeats: NO] retain];
        }
    } else {
        NSTimeInterval delay;

        delay = [_lastUpdateRequestDate timeIntervalSinceNow] + 1.0/60.0;
        if (_lastUpdateRequestDate && delay > 0.0) {
            /* Delays update request so that we send at most 60/second, which is
               fast as will be visible. Note that an NSTimer will be too slow to
               be responsive here. */
            struct timespec t;
            t.tv_sec = 0;
            t.tv_nsec = (long) (delay * 1000.0 * 1000.0 * 1000.0);
            nanosleep(&t, NULL);
        }

        [self requestFrameBufferUpdate: nil];
    }

}

/* Send incremental update request for whole framebuffer */
- (void)requestFrameBufferUpdate:(id)sender {
	[_frameUpdateTimer invalidate];
	[_frameUpdateTimer release];
	_frameUpdateTimer = nil;

    [self requestUpdate:[rfbView bounds] incremental:YES];
}

// Force an immediate frame buffer update
- (void)forceFrameBufferUpdate {
    [self requestUpdate:[rfbView bounds] incremental:NO];
}

- (void)requestUpdate:(NSRect)frame incremental:(BOOL)aFlag
{
    rfbFramebufferUpdateRequestMsg	msg;
    memset(&msg, 0, sizeof(msg));

    DiagnosticLog(DiagnosticLogLevelVerbose, @"RFBConnection requestUpdate: origin=(%.0f, %.0f) size=(%.0f x %.0f) incremental=%d",
           frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, aFlag);

    msg.type = rfbFramebufferUpdateRequest;
    msg.incremental = aFlag;
    // :TORESOLVE: do coordinates need to be translated here?
    msg.x = frame.origin.x; msg.x = htons(msg.x);
    msg.y = frame.origin.y; msg.y = htons(msg.y);
    msg.w = frame.size.width; msg.w = htons(msg.w);
    msg.h = frame.size.height; msg.h = htons(msg.h);
    [self writeBytes:(unsigned char*)&msg length:sz_rfbFramebufferUpdateRequestMsg];

    [_lastUpdateRequestDate release];
    _lastUpdateRequestDate = [[NSDate alloc] init];
}

/* The server has moved the cursor to pos in RFB coordinates */
- (void)serverMovedMouseTo:(NSPoint)pos
{
    if ([session hasKeyWindow] && -[lastMouseMovement timeIntervalSinceNow] > 0.5
            && ![server_ viewOnly])
    {
        NSSize  size = [frameBuffer size];
        CGPoint screenCoords;
        NSWindow *window = [rfbView window];

        pos.y = size.height - pos.y;
        pos = [rfbView convertPoint:pos toView:nil];
        pos = [window convertPointToScreen:pos];
        if (!NSPointInRect(pos, [window frame]))
            return;
        screenCoords.x = pos.x;
        screenCoords.y = CGDisplayPixelsHigh(CGMainDisplayID()) - pos.y;
        CGWarpMouseCursorPosition(screenCoords);
    }
}

/* Translates a coordinate point into an RFB message. Also records the mouse
 * movement in lastMouseMovement. */
- (void)putPosition:(NSPoint)thePoint inPointerMessage:(rfbPointerEventMsg *)msg
{
    NSRect b = [rfbView bounds];
    NSSize s = [frameBuffer size];

    if(thePoint.x < 0) thePoint.x = 0;
    if(thePoint.y < 0) thePoint.y = 0;
    if(thePoint.x > s.width - 1) thePoint.x = s.width - 1;
    if(thePoint.y > s.height - 1) thePoint.y = s.height - 1;

    msg->x = htons((CARD16) thePoint.x);
    msg->y = htons((CARD16) (b.size.height - thePoint.y));

    [lastMouseMovement release];
    lastMouseMovement = [[NSDate alloc] init];
}

- (void)mouseAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    rfbPointerEventMsg  msg;

    msg.type = rfbPointerEvent;
    DiagnosticLog(DiagnosticLogLevelVerbose, @"RFBConnection sendType: sent client message type %u (rfbPointerEvent)", rfbPointerEvent);
    msg.buttonMask = mask;
    [self putPosition:thePoint inPointerMessage:&msg];

    if (msg.x == lastMouseX && msg.y == lastMouseY)
        return;

    if (lastBufferedIsMouseMovement)
        bufferLen -= sizeof(msg); // coalesce successive mouse movements

    if (isReceivingUpdate) {
        [self writeBufferedBytes: (unsigned char *)&msg length:sizeof(msg)];
        lastBufferedIsMouseMovement = YES;
    } else {
        [self writeBytes: (unsigned char *)&msg length:sizeof(msg)];
        lastBufferedIsMouseMovement = NO;
    }

    lastMouseX = msg.x;
    lastMouseY = msg.y;
}

- (void)mouseClickedAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    // @@ Send clipboard before sending middle mouse down
    if (mask & rfbButton2Mask)
    {
        [self sendPasteboardToServer:[NSPasteboard generalPasteboard]];
    }

    rfbPointerEventMsg msg;
	
    msg.type = rfbPointerEvent;
    msg.buttonMask = mask;
    [self putPosition:thePoint inPointerMessage:&msg];

    [self writeBufferedBytes: (unsigned char *)&msg length:sizeof(msg)];

    lastMouseX = msg.x;
    lastMouseY = msg.y;
}

- (void)sendModifier:(unsigned int)m pressed: (BOOL)pressed
{
	/*NSString *modifierStr =nil;
	switch (m)
	{
		case NSShiftKeyMask:
			modifierStr = @"NSShiftKeyMask";		break;
		case NSControlKeyMask:
			modifierStr = @"NSControlKeyMask";		break;
		case NSAlternateKeyMask:
			modifierStr = @"NSAlternateKeyMask";	break;
		case NSCommandKeyMask:
			modifierStr = @"NSCommandKeyMask";		break;
		case NSAlphaShiftKeyMask:
			modifierStr = @"NSAlphaShiftKeyMask";	break;
	}
	NSLog(@"modifier %@ %s", modifierStr, pressed ? "pressed" : "released"); */

    rfbKeyEventMsg msg;

    memset(&msg, 0, sizeof(msg));
    msg.type = rfbKeyEvent;
    DiagnosticLog(DiagnosticLogLevelVerbose, @"RFBConnection sendType: sent client message type %u (rfbKeyEvent)", rfbKeyEvent);
	msg.down = pressed;
	
    if( NSEventModifierFlagShift == m )
        msg.key = htonl([_profile shiftKeyCode]);
    else if( NSEventModifierFlagControl == m )
        msg.key = htonl([_profile controlKeyCode]);
    else if( NSEventModifierFlagOption == m )
        msg.key = htonl([_profile altKeyCode]);
    else if( NSEventModifierFlagCommand == m )
        msg.key = htonl([_profile commandKeyCode]);
    else if(NSEventModifierFlagCapsLock == m)
        msg.key = htonl(XK_Caps_Lock);
    else if(NSEventModifierFlagHelp == m)		// this is F1
        msg.key = htonl(XK_F1);
    else if (NSEventModifierFlagNumericPad == m) // don't know how to handle, eat it
		return;
	
    // XK_VoidSymbol is used for unbound modifier keys
    if (msg.key != htonl(XK_VoidSymbol)) {
        [self writeBufferedBytes:(unsigned char*)&msg length:sizeof(msg)];
    }
}

/* --------------------------------------------------------------------------------- */
- (void)sendKey:(unichar)c pressed:(BOOL)pressed
{
    rfbKeyEventMsg msg;
    unsigned int keysym = 0;

    if (pressed)
        pressed = 1; // make sure it's 0 or 1 for index

    memset(&msg, 0, sizeof(msg));
    msg.type = rfbKeyEvent;
    DiagnosticLog(DiagnosticLogLevelVerbose, @"RFBConnection sendType: sent client message type %u (rfbKeyEvent)", rfbKeyEvent);
    msg.down = pressed;

    if ((c & 0xf800) == 0xd800) { // surrogate code point
        /* The unichar type is not really a unicode code point, because it is
         * only 16-bit, so it codes non-BMP characters using surrogate pairs.
         * Here, we coalesce successive key events for surrogate pairs into a
         * single key event, using highSurrogate. */
        if (c & 0x0400) { // low surrogate
            if (highSurrogate[pressed]) {
                keysym = 0x01000000 // keysym offset for Unicode
                            + 0x00010000 // non-Basic Multilingual Plane offset
                            + ((highSurrogate[pressed] - 0xd800) << 10)
                            + (c - 0xdc00);
                highSurrogate[pressed] = 0;
            } else
                return;
        } else { // high surrogate
            highSurrogate[pressed] = c;
            return;
        }
    } else {
        highSurrogate[pressed] = 0;

        switch (c & 0xff80) {
            case 0x0000: // ASCII
            case 0x0080: // Latin-I supplement
                keysym = page0[c];
                if (keysym == 0)
                    return;
                break;
            case 0x0100: keysym = page1[c & 0x7f]; break; // Latin Extended-A
            case 0x0380: keysym = page3[c & 0x7f]; break; // Greek
            case 0x0400: keysym = page4[c & 0x7f]; break; // Cyrillic
            case 0x0580:
                if (c & 0x040)
                    keysym = page5[c & 0x3f]; // Hebrew
                break;
            case 0x0600: keysym = page6[c & 0x7f]; break; // Arabic
            case 0x0e00: keysym = pagee[c & 0x7f]; break; // Thai
            case 0x3080: keysym = page30[c & 0x7f]; break; // Japanese
            case 0xf600:
                if (c < 0xf640) {
                    keysym = pagef6[c & 0x3f]; // key pad
                    if (keysym == 0)
                        return;
                }
                break;
            case 0xf700:
                keysym = pagef7[c & 0x7f]; // Apple's function keys
                if (keysym == 0) // don't send special-use Unicode characters
                    return;
                break;
        }

        if (keysym == 0)
            keysym = c + 0x01000000; // default: map character algorithmically
    }

    msg.key = htonl(keysym);
    [self writeBufferedBytes:(unsigned char*)&msg length:sizeof(msg)];
}

/* Send a raw (RFB) key code. Used for simulated key sequences. */
- (void)sendKeyCode: (CARD32)key pressed: (BOOL)pressed
{
    rfbKeyEventMsg msg;
	
    msg.type = rfbKeyEvent;
    DiagnosticLog(DiagnosticLogLevelVerbose, @"RFBConnection sendType: sent client message type %u (rfbKeyEvent)", rfbKeyEvent);
    msg.down = pressed;
    msg.pad = 0;
	msg.key = htonl(key);
    [self writeBufferedBytes: (unsigned char*)&msg length:sizeof(msg)];
}

- (BOOL)pasteFromPasteboard:(NSPasteboard*)pb
{
    id types, theType;
	NSString *str;
	
    types = [NSArray arrayWithObjects:NSPasteboardTypeString, NSFilenamesPboardType, nil];
    if((theType = [pb availableTypeFromArray:types]) == nil) {
        NSLog(@"No supported pasteboard type\n");
        return NO;
    }
    str = [pb stringForType:theType];
    if([str isKindOfClass:[NSArray class]]) {
        str = [(id)str objectAtIndex:0];
    }
    
	[_eventFilter pasteString: str];
    return YES;
}

static NSData *compressZlib(NSData *uncompressedData) {
    if ([uncompressedData length] == 0) return uncompressedData;
    
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)[uncompressedData bytes];
    strm.avail_in = (uInt)[uncompressedData length];
    
    if (deflateInit(&strm, Z_DEFAULT_COMPRESSION) != Z_OK) {
        return nil;
    }
    
    NSMutableData *compressed = [NSMutableData data];
    unsigned char buffer[4096];
    int status;
    
    do {
        strm.next_out = buffer;
        strm.avail_out = sizeof(buffer);
        status = deflate(&strm, Z_SYNC_FLUSH);
        if (status < 0) {
            deflateEnd(&strm);
            return nil;
        }
        [compressed appendBytes:buffer length:(sizeof(buffer) - strm.avail_out)];
    } while (strm.avail_out == 0);
    
    deflateEnd(&strm);
    return compressed;
}

- (BOOL)isAppleServer
{
    return isAppleServer;
}

- (void)setIsAppleServer:(BOOL)flag
{
    isAppleServer = flag;
    if (isAppleServer) {
        _serverSupportsSetDesktopSize = NO;
    }
}

- (BOOL)serverSupportsExtendedClipboard
{
    return serverSupportsExtendedClipboard;
}

- (void)setServerSupportsExtendedClipboard:(BOOL)flag
{
    serverSupportsExtendedClipboard = flag;
}

- (uint32_t)serverClipboardFlags
{
    return serverClipboardFlags;
}

- (void)setServerClipboardFlags:(uint32_t)flags
{
    serverClipboardFlags = flags;
}

- (void)sendClipboardCaps
{
    unsigned char buf[16];
    buf[0] = rfbClientCutText;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbClientCutText)", rfbClientCutText);
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    
    int32_t lenVal = htonl(-8);
    memcpy(buf + 4, &lenVal, 4);
    
    uint32_t flagsVal = htonl(0x1B000001);
    memcpy(buf + 8, &flagsVal, 4);
    
    uint32_t sizeVal = htonl(0);
    memcpy(buf + 12, &sizeVal, 4);
    
    [self writeBytes:buf length:16];
}

- (void)sendClipboardRequest
{
    unsigned char buf[12];
    buf[0] = rfbClientCutText;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbClientCutText)", rfbClientCutText);
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    
    int32_t lenVal = htonl(-4);
    memcpy(buf + 4, &lenVal, 4);
    
    uint32_t flagsVal = htonl(0x02000001);
    memcpy(buf + 8, &flagsVal, 4);
    
    [self writeBytes:buf length:12];
}

- (void)sendClipboardNotify:(BOOL)available
{
    unsigned char buf[12];
    buf[0] = rfbClientCutText;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbClientCutText)", rfbClientCutText);
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    
    int32_t lenVal = htonl(-4);
    memcpy(buf + 4, &lenVal, 4);
    
    uint32_t flagsVal = htonl(0x08000000 | (available ? 0x00000001 : 0));
    memcpy(buf + 8, &flagsVal, 4);
    
    [self writeBytes:buf length:12];
}

- (void)sendClipboardProvide:(NSString *)str
{
    NSData *utf8Data = [str dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8Data) {
        return;
    }
    
    NSMutableData *payload = [NSMutableData data];
    uint32_t utf8Len = htonl((uint32_t)[utf8Data length]);
    [payload appendBytes:&utf8Len length:4];
    [payload appendData:utf8Data];
    
    NSData *compressed = compressZlib(payload);
    if (!compressed) {
        NSLog(@"Failed to compress clipboard data");
        return;
    }
    
    unsigned int msgSz = 12 + [compressed length];
    unsigned char *buf = malloc(msgSz);
    if (!buf) {
        NSLog(@"Out of memory allocating clipboard send buffer");
        return;
    }
    
    buf[0] = rfbClientCutText;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbClientCutText)", rfbClientCutText);
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    
    int32_t lenVal = htonl(-(4 + (int32_t)[compressed length]));
    memcpy(buf + 4, &lenVal, 4);
    
    uint32_t flagsVal = htonl(0x10000001);
    memcpy(buf + 8, &flagsVal, 4);
    
    memcpy(buf + 12, [compressed bytes], [compressed length]);
    
    [self writeBytes:buf length:msgSz];
    free(buf);
}

- (void)sendPasteboardToServer:(NSPasteboard *)pb
{
    NSString    *str = [pb stringForType:NSPasteboardTypeString];
    
    if (serverSupportsExtendedClipboard) {
        [self sendClipboardNotify:(str != nil && [str length] > 0)];
        return;
    }
    
    const char  *cStr = [str cStringUsingEncoding:NSISOLatin1StringEncoding];

#if 0 // just don't send if not convertible
    if (cStr == NULL) {
        NSBeginAlertSheet(NSLocalizedString(@"PasteConversionHeader", nil), 
                          NSLocalizedString(@"PasteAnyways", nil),
                          NSLocalizedString(@"Cancel", nil), nil,
                          [rfbView window], self,
                          @selector(pasteConfirmation:returnCode:contextInfo:),
                          nil, [str retain], /* This retain is balanced by the
                                              * release in pasteConfirmation: */
                          NSLocalizedString(@"PasteConversionBody", nil));
    } else
#else
    if (cStr != NULL)
#endif
        [self sendStringToServersClipboard:cStr length:strlen(cStr)];
}

- (void)sendStringToServersClipboard:(const char *)cStr length:(unsigned)len
{
    if ([server_ viewOnly])
        return;
    
    unsigned int            msgSz = sizeof(rfbClientCutTextMsg) + len;
    rfbClientCutTextMsg     *msg = malloc(msgSz);

    if (msg == NULL) {
        NSLog(@"Not enough memory to store pasteboard contents");
        return;
    }

    msg->type = rfbClientCutText;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbClientCutText)", rfbClientCutText);
    msg->length = htonl(len);
    memcpy((char *)(msg + 1), cStr, len);
    [self writeBytes:(unsigned char *)msg length:msgSz];
    free(msg);
}

- (void)pasteConfirmation:(NSWindow *)sheet returnCode:(int)code
              contextInfo:(NSString *)str
{
    if (code == NSAlertDefaultReturn) {
        NSData  *data = [str dataUsingEncoding:NSISOLatin1StringEncoding
                          allowLossyConversion:YES];
        [self sendStringToServersClipboard:[data bytes] length:[data length]];
    }
    [str release]; // balances retain in sendPasteboardToServer:
}

- (EventFilter *)eventFilter
{  return _eventFilter;  }

- (Session *)session
{
    return session;
}

- (SshTunnel *)sshTunnel
{
    return sshTunnel;
}

- (void)reallyWriteBytes:(unsigned char*)bytes length:(unsigned int)length
{
    int result;
    int written = 0;

    if (IsDiagnosticLoggingEnabled(DiagnosticLogLevelVerbose)) {
        NSMutableString *hexStr = [NSMutableString string];
        NSUInteger dumpLen = length < 32 ? length : 32;
        for (NSUInteger i = 0; i < dumpLen; i++) {
            [hexStr appendFormat:@"%02X ", bytes[i]];
        }
        if (length > 32) [hexStr appendString:@"..."];
        DiagnosticLog(DiagnosticLogLevelVerbose, @"Socket write %u bytes [Type byte: %d]: %@", length, length > 0 ? bytes[0] : -1, hexStr);
    }

    do {
        result = write([socketHandler fileDescriptor], bytes + written, length);
        if(result >= 0) {
            length -= result;
            written += result;
        } else {
            if(errno == EAGAIN) {
                continue;
            }
            if(errno == EPIPE) {
                DiagnosticLog(DiagnosticLogLevelBasic, @"Socket write failed with EPIPE (Server closed connection)");
				NSString *reason = NSLocalizedString( @"ServerClosed", nil );
                [self terminateConnection:reason];
                return;
            }
            DiagnosticLog(DiagnosticLogLevelBasic, @"Socket write failed with errno %d (%s)", errno, strerror(errno));
			NSString *reason = NSLocalizedString( @"ServerError", nil );
			reason = [NSString stringWithFormat: reason, strerror(errno)];
            [self terminateConnection:reason];
            return;
        }
    } while(length > 0);
}

- (void)writeBytes:(unsigned char *)bytes length:(unsigned int)length
{
    if (bufferLen > 0) {
        [self writeBufferedBytes:bytes length:length];
        [self writeBuffer];
    } else
        [self reallyWriteBytes:bytes length:length];
}

/* Writes the bytes to a buffer. Note that the buffering reduces context
 * switches to the kernel and network traffic. */
- (void)writeBufferedBytes:(unsigned char *)bytes length:(unsigned int)length
{
    if (bufferLen + length > BUFFER_SIZE) {
        [self writeBuffer];
        if (length > BUFFER_SIZE) {
            [self reallyWriteBytes: bytes length: length];
            return;
        }
    }

    memcpy(writeBuffer + bufferLen, bytes, length);
    bufferLen += length;
    lastBufferedIsMouseMovement = NO;
}

- (void)writeBuffer
{
    if (bufferLen == 0)
        return;

    [self reallyWriteBytes:writeBuffer length:bufferLen];
    bufferLen = 0;
    lastBufferedIsMouseMovement = NO;
}

- (void)writeRFBString:(NSString *)aString {
    const char	*str = [aString UTF8String]; // null-terminated utf8-encoded string
	CARD32      len=htonl(strlen(str));
	[self writeBufferedBytes:(unsigned char *)&len length:4];
	[self writeBufferedBytes:(unsigned char *)str length:len];
}

- (void)writeSetDesktopSize:(NSSize)size
{
    rfbSetDesktopSizeMsg msg;
    rfbScreenLayout screen;

    if (isAppleServer || !_serverSupportsSetDesktopSize) {
        return;
    }

    // Avoid sending duplicate sizes and debounce rapid resize events
    NSDate *now = [NSDate date];
    if (NSEqualSizes(size, lastDesktopSizeSent) &&
        lastDesktopSizeTime != nil &&
        [now timeIntervalSinceDate:lastDesktopSizeTime] < 0.1) {
        // Same size as last sent, and sent within last 100ms - skip
        return;
    }

    // Build the message header
    msg.type = rfbSetDesktopSize;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBConnection sendType: sent client message type %u (rfbSetDesktopSize)", rfbSetDesktopSize);
    msg.pad1 = 0;
    msg.width = htons((CARD16)size.width);
    msg.height = htons((CARD16)size.height);
    msg.numScreens = 1;
    msg.pad2 = 0;

    // Send message header
    [self writeBytes:(unsigned char*)&msg length:sz_rfbSetDesktopSizeMsg];

    // Build and send single screen layout
    screen.id = htonl(0);
    screen.x = htons(0);
    screen.y = htons(0);
    screen.width = htons((CARD16)size.width);
    screen.height = htons((CARD16)size.height);
    screen.flags = htonl(0);

    [self writeBytes:(unsigned char*)&screen length:sz_rfbScreenLayout];

    // Update tracking
    lastDesktopSizeSent = size;
    [lastDesktopSizeTime release];
    lastDesktopSizeTime = [[NSDate date] retain];
}

- (void)viewFrameDidChange:(NSNotification *)aNotification
{
	[self removeMouseMovedTrackingRect];
	[self installMouseMovedTrackingRect];
    [[rfbView window] invalidateCursorRectsForView: rfbView];
}

- (NSString *)infoString
{
    NSString    *endian;
    NSString    *trueColor;

    endian = NSLocalizedString([frameBuffer serverIsBigEndian] ?  @"big-endian" : @"little-endian", nil);
    trueColor = NSLocalizedString(frameBuffer->pixelFormat.trueColour ? @"yes" : @"no", nil);

    return
        [NSString stringWithFormat: NSLocalizedString(@"ServerInfo", nil),
                serverMajorVersion, serverMinorVersion,
                (int)[frameBuffer size].width, (int)[frameBuffer size].height,
                frameBuffer->pixelFormat.bitsPerPixel,
                frameBuffer->pixelFormat.depth, endian, trueColor,
                frameBuffer->pixelFormat.redMax,
                frameBuffer->pixelFormat.greenMax,
                frameBuffer->pixelFormat.blueMax,
                frameBuffer->pixelFormat.redShift,
                frameBuffer->pixelFormat.greenShift,
                frameBuffer->pixelFormat.blueShift];
}

static NSString* byteString(double d)
{
    if(d < 10000) {
        return [NSString stringWithFormat:@"%u", (unsigned)d];
    } else if(d < (1024*1024)) {
        return [NSString stringWithFormat:@"%.2fKB", d / 1024];
    } else if(d < (1024*1024*1024)) {
        return [NSString stringWithFormat:@"%.2fMB", d / (1024*1024)];
    } else {
        return [NSString stringWithFormat:@"%.2fGB", d / (1024*1024*1024)];
    }
}

- (NSString *)statisticsString
{
    FrameBufferUpdateReader* reader = [rfbProtocol frameBufferUpdateReader];
    double  represented = [reader bytesRepresented];

    return
        [NSString stringWithFormat: NSLocalizedString(@"ConnectionStatistics", nil),
            byteString(bytesReceived), byteString(represented),
            represented/bytesReceived, (unsigned)[reader rectanglesTransferred],
            [reader rectsByTypeString]
    	];
}

- (void)installMouseMovedTrackingRect
{
    NSWindow *window = [rfbView window];
    NSPoint mousePoint = [rfbView convertPoint: [window convertPointFromScreen: [NSEvent mouseLocation]] fromView: nil];
	BOOL mouseInVisibleRect = [rfbView mouse: mousePoint inRect: [rfbView visibleRect]];

    if (_mouseMovedTrackingTag)
        [rfbView removeTrackingRect: _mouseMovedTrackingTag];
	_mouseMovedTrackingTag = [rfbView addTrackingRect: [rfbView bounds] owner: self userData: nil assumeInside: mouseInVisibleRect];
	if (mouseInVisibleRect)
		[window setAcceptsMouseMovedEvents: YES];
}

- (void)removeMouseMovedTrackingRect
{
    if (_mouseMovedTrackingTag)
    {
        [rfbView removeTrackingRect: _mouseMovedTrackingTag];
        [[rfbView window] setAcceptsMouseMovedEvents: NO];
        _mouseMovedTrackingTag = 0;
    }
}

- (void)mouseEntered:(NSEvent *)theEvent {
    [[rfbView window] setAcceptsMouseMovedEvents: YES];
}

- (void)mouseExited:(NSEvent *)theEvent {
    [[rfbView window] setAcceptsMouseMovedEvents: NO];
}



- (void)setFrameBufferUpdateSeconds: (float)seconds {
    int     hadManualUpdates = _hasManualFrameBufferUpdates;

	_frameBufferUpdateSeconds = seconds;
	_hasManualFrameBufferUpdates = _frameBufferUpdateSeconds >= [[PrefController sharedController] maxPossibleFrameBufferUpdateSeconds];

    if (hadManualUpdates && !_hasManualFrameBufferUpdates)
        [self requestFrameBufferUpdate:nil];
}

@end
