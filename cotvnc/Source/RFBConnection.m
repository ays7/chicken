/* Copyright (C) 2026 The Chicken Fork Authors
 * Copyright (C) 1998-2000  Helmut Maierhofer <helmut.maierhofer@chello.at>
 */

#import "RFBConnection.h"
#import "Session.h"
#import "SshTunnel.h"
#import "Profile.h"
#import "Keymap.h"

#define XK_MISCELLANY
#include "keysymdef.h"

@import RoyalVNCKit;

#import "EventFilter.h"

/* ---------------------------------------------------------------------------
 * EventFilterViewDelegate
 * Routes all NSEvent-level mouse and keyboard events that VNCCAFramebufferView
 * would otherwise handle directly, through the Chicken EventFilter so that
 * profile-based emulation (click-while-holding, multi-tap, etc.) works.
 * --------------------------------------------------------------------------- */
@interface EventFilterViewDelegate : NSObject <VNCInputEventDelegate>
- (instancetype)initWithEventFilter:(EventFilter *)filter;
@end

@implementation EventFilterViewDelegate {
    EventFilter *_filter;
}

- (instancetype)initWithEventFilter:(EventFilter *)filter {
    if (self = [super init]) {
        _filter = [filter retain];
    }
    return self;
}

- (void)dealloc {
    [_filter release];
    [super dealloc];
}

// ---- Mouse ----

- (BOOL)vncView:(VNCCAFramebufferView *)view mouseDown:(NSEvent *)event {
    [_filter mouseDown:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view mouseUp:(NSEvent *)event {
    [_filter mouseUp:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view mouseDragged:(NSEvent *)event {
    [_filter mouseDragged:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view rightMouseDown:(NSEvent *)event {
    [_filter rightMouseDown:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view rightMouseUp:(NSEvent *)event {
    [_filter rightMouseUp:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view rightMouseDragged:(NSEvent *)event {
    [_filter rightMouseDragged:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view otherMouseDown:(NSEvent *)event {
    [_filter otherMouseDown:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view otherMouseUp:(NSEvent *)event {
    [_filter otherMouseUp:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view otherMouseDragged:(NSEvent *)event {
    [_filter otherMouseDragged:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view scrollWheel:(NSEvent *)event {
    [_filter scrollWheel:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view mouseMoved:(NSEvent *)event {
    [_filter mouseMoved:event];
    return YES;
}

// ---- Keyboard ----

- (BOOL)vncView:(VNCCAFramebufferView *)view keyDown:(NSEvent *)event {
    [_filter keyDown:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view keyUp:(NSEvent *)event {
    [_filter keyUp:event];
    return YES;
}
- (BOOL)vncView:(VNCCAFramebufferView *)view flagsChanged:(NSEvent *)event {
    [_filter flagsChanged:event];
    return YES;
}

@end

@implementation RFBConnection

+ (void)initialize {
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithFloat: 0.0], @"FrameBufferUpdateSeconds", nil];
    [standardUserDefaults registerDefaults: dict];
}

- (id)initWithFileHandle:(NSFileHandle*)file server:(id<IServerData>)server
{
    return [self initWithFileHandle:file server:server host:nil port:0];
}

- (id)initWithFileHandle:(NSFileHandle*)file server:(id<IServerData>)server host:(NSString *)resolvedHost port:(int)resolvedPort
{
    if (self = [super init]) {
        server_ = [(id)server retain];
        password = [[server password] retain];
        _profile = [[server profile] retain];
        
        resolvedHost_ = [resolvedHost retain];
        resolvedPort_ = resolvedPort;
        
        // Close the temp file descriptor as RoyalVNCKit handles its own socket creation and connection
        [file closeFile];
        
        authCompletion = nil;
        pendingAuthType = 0;
    }
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (session) {
        [NSObject cancelPreviousPerformRequestsWithTarget:session];
        session = nil;
    }
    if (authCompletion) {
        [authCompletion release];
    }
    
    [resolvedHost_ release];
    
    [_eventFilterDelegate release];
    _eventFilterDelegate = nil;
    [_eventFilter release];
    _eventFilter = nil;
    
    [connection disconnect];
    [connection setDelegate:nil];
    [connection release];
    
    [rfbView release];
    [server_ release];
    [password release];
    [_profile release];
    [sshTunnel release];
    [super dealloc];
}

- (void)closeConnection
{
    [connection disconnect];
    rfbView = nil;
    session = nil;
}

- (id<IServerData>)server
{
    return server_;
}

- (void)startVncConnection
{
    NSString *hostStr = resolvedHost_ ? resolvedHost_ : [server_ host];
    uint16_t portVal = (resolvedPort_ > 0) ? (uint16_t)resolvedPort_ : (uint16_t)[server_ port];
    
    if (sshTunnel) {
        hostStr = @"localhost";
        portVal = [sshTunnel localPort];
    }
    
    // Setup standard frame encodings
    // VNCFrameEncodingType: raw = 0, copyRect = 1, rre = 2, coRRE = 4, hextile = 5, zlib = 6, tight = 7, zrle = 16
    NSArray *encodings = @[@(16), @(7), @(6), @(5), @(4), @(2), @(1), @(0)];
    
    VNCConnectionSettings *settings = [[VNCConnectionSettings alloc] initWithIsDebugLoggingEnabled:NO
                                                                                          hostname:hostStr
                                                                                              port:portVal
                                                                                          isShared:[server_ shared]
                                                                                  isScalingEnabled:YES
                                                                                    useDisplayLink:NO
                                                                                         inputMode:VNCInputModeForwardKeyboardShortcutsEvenIfInUseLocally
                                                                      isClipboardRedirectionEnabled:YES
                                                                          isClipboardMonitorEnabled:NO
                                                                                        colorDepth:VNCColorDepthDepth24Bit
                                                                                    frameEncodings:encodings];
    
    connection = [[VNCConnection alloc] initWithSettings:settings];
    [connection setDelegate:self];
    [settings release];
    
    [connection connect];
}

- (void)setRfbView:(VNCCAFramebufferView *)view
{
    [rfbView release];
    rfbView = [view retain];

    // Only wire up the EventFilter when we have a real VNCCAFramebufferView.
    // The first call from Session.initWithConnection: passes the NIB placeholder NSView.
    if ([view isKindOfClass:[VNCCAFramebufferView class]]) {
        if (!_eventFilter) {
            _eventFilter = [[EventFilter alloc] init];
            [_eventFilter setConnection:self];
            [_eventFilter setView:view];

            _eventFilterDelegate = [[EventFilterViewDelegate alloc] initWithEventFilter:_eventFilter];
        } else {
            [_eventFilter setView:view];
        }
        view.inputEventDelegate = _eventFilterDelegate;
    }

    if (connection == nil) {
        [self startVncConnection];
    }
}

- (void)setSession:(Session *)aSession
{
    session = aSession;
}

- (void)setPassword:(NSString *)newPassword
{
    [password release];
    password = [newPassword retain];
    
    if (authCompletion) {
        VNCCredential *cred = nil;
        BOOL requiresUsername = [VNCAuthenticationTypeUtils authenticationTypeRequiresUsername:pendingAuthType];
        if (requiresUsername) {
            cred = (id)[[VNCUsernamePasswordCredential alloc] initWithUsername:NSUserName() password:password];
        } else {
            cred = (id)[[VNCPasswordCredential alloc] initWithPassword:password];
        }
        authCompletion(cred);
        [cred release];
        [authCompletion release];
        authCompletion = nil;
    }
}

- (void)setSshTunnel:(SshTunnel *)tunnel
{
    [sshTunnel release];
    sshTunnel = [tunnel retain];
}

- (BOOL)pasteFromPasteboard:(NSPasteboard*)pb
{
    return YES;
}

- (void)sendPasteboardToServer:(NSPasteboard *)pb
{
    NSLog(@"[Chicken] sendPasteboardToServer called");
    if ([self viewOnly]) {
        NSLog(@"[Chicken] sendPasteboardToServer ignored: viewOnly is YES");
        return;
    }
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    NSLog(@"[Chicken] sendPasteboardToServer pasteboard string: %@", str);
    if (str && [str length] > 0) {
        NSLog(@"[Chicken] sendPasteboardToServer enqueuing ClientCutText");
        [connection enqueueClientCutTextMessage:str];
    }
}

- (BOOL)serverSupportsSetDesktopSize
{
    // Delegate to RoyalVNCKit: SetDesktopSize requires RFB protocol version 3.8 or later.
    // The agreed protocol version is determined during the RFB handshake; checking it here
    // is authoritative, unlike the previous heuristic of inferring support from a resize event.
    return [connection serverSupportsSetDesktopSize];
}

- (void)terminateConnection:(NSString*)aReason
{
    [session performSelectorOnMainThread:@selector(terminateConnection:) withObject:aReason waitUntilDone:NO];
}

- (void)authenticationFailed:(NSString *)aReason
{
    [session performSelectorOnMainThread:@selector(authenticationFailed:) withObject:aReason waitUntilDone:NO];
}

- (void)promptForPassword
{
    [session performSelectorOnMainThread:@selector(promptForPassword) withObject:nil waitUntilDone:NO];
}

/* ----------------- Input Event Forwarding ----------------- */

- (void)sendMouseMask:(unsigned int)mask x:(uint16_t)x y:(uint16_t)y
{
    static unsigned int lastSentMask = 0;
    
    BOOL lastLeft = (lastSentMask & 1) != 0;
    BOOL currentLeft = (mask & 1) != 0;
    if (currentLeft != lastLeft) {
        if (currentLeft) [connection mouseButtonDown:VNCMouseButtonLeft x:x y:y];
        else [connection mouseButtonUp:VNCMouseButtonLeft x:x y:y];
    }
    
    BOOL lastMiddle = (lastSentMask & 2) != 0;
    BOOL currentMiddle = (mask & 2) != 0;
    if (currentMiddle != lastMiddle) {
        if (currentMiddle) [connection mouseButtonDown:VNCMouseButtonMiddle x:x y:y];
        else [connection mouseButtonUp:VNCMouseButtonMiddle x:x y:y];
    }
    
    BOOL lastRight = (lastSentMask & 4) != 0;
    BOOL currentRight = (mask & 4) != 0;
    if (currentRight != lastRight) {
        if (currentRight) [connection mouseButtonDown:VNCMouseButtonRight x:x y:y];
        else [connection mouseButtonUp:VNCMouseButtonRight x:x y:y];
    }
    
    if (currentLeft == lastLeft && currentMiddle == lastMiddle && currentRight == lastRight) {
        [connection mouseMoveWithX:x y:y];
    }
    
    lastSentMask = mask;
}

- (void)mouseAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    NSSize s = NSMakeSize(connection.framebuffer.size.width, connection.framebuffer.size.height);
    if (thePoint.x < 0) thePoint.x = 0;
    if (thePoint.y < 0) thePoint.y = 0;
    if (thePoint.x > s.width - 1) thePoint.x = s.width - 1;
    if (thePoint.y > s.height - 1) thePoint.y = s.height - 1;

    uint16_t x = (uint16_t)thePoint.x;
    uint16_t y = (uint16_t)([rfbView bounds].size.height - thePoint.y);
    
    if (mask & 8) {
        [connection mouseWheel:VNCMouseWheelUp x:x y:y steps:1];
        mask &= ~8;
    }
    if (mask & 16) {
        [connection mouseWheel:VNCMouseWheelDown x:x y:y steps:1];
        mask &= ~16;
    }
    if (mask & 32) {
        [connection mouseWheel:VNCMouseWheelLeft x:x y:y steps:1];
        mask &= ~32;
    }
    if (mask & 64) {
        [connection mouseWheel:VNCMouseWheelRight x:x y:y steps:1];
        mask &= ~64;
    }

    [self sendMouseMask:mask x:x y:y];
}

- (void)mouseClickedAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    [self mouseAt:thePoint buttons:mask];
}

- (void)sendKeyCode:(CARD32)key pressed:(BOOL)pressed
{
    if (pressed) {
        [connection keyDown:key];
    } else {
        [connection keyUp:key];
    }
}

- (void)sendKey:(unichar)c pressed:(BOOL)pressed
{
    static unichar highSurrogate[2] = {0, 0};
    unsigned int keysym = 0;

    if (pressed)
        pressed = 1;

    if ((c & 0xf800) == 0xd800) {
        if (c & 0x0400) { // low surrogate
            if (highSurrogate[pressed]) {
                keysym = 0x01000000 + 0x00010000 + ((highSurrogate[pressed] - 0xd800) << 10) + (c - 0xdc00);
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
            case 0x0000:
            case 0x0080:
                keysym = page0[c];
                if (keysym == 0)
                    return;
                break;
            case 0x0100: keysym = page1[c & 0x7f]; break;
            case 0x0380: keysym = page3[c & 0x7f]; break;
            case 0x0400: keysym = page4[c & 0x7f]; break;
            case 0x0580:
                if (c & 0x040)
                    keysym = page5[c & 0x3f];
                break;
            case 0x0600: keysym = page6[c & 0x7f]; break;
            case 0x0e00: keysym = pagee[c & 0x7f]; break;
            case 0x3080: keysym = page30[c & 0x7f]; break;
            case 0xf600:
                if (c < 0xf640) {
                    keysym = pagef6[c & 0x3f];
                    if (keysym == 0)
                        return;
                }
                break;
            case 0xf700:
                keysym = pagef7[c & 0x7f];
                if (keysym == 0)
                    return;
                break;
        }

        if (keysym == 0)
            keysym = c + 0x01000000;
    }

    [self sendKeyCode:keysym pressed:pressed];
}

- (void)sendModifier:(unsigned int)m pressed:(BOOL)pressed
{
    unsigned int key = 0;
    if( NSEventModifierFlagShift == m )
        key = [_profile shiftKeyCode];
    else if( NSEventModifierFlagControl == m )
        key = [_profile controlKeyCode];
    else if( NSEventModifierFlagOption == m )
        key = [_profile altKeyCode];
    else if( NSEventModifierFlagCommand == m )
        key = [_profile commandKeyCode];
    else if(NSEventModifierFlagCapsLock == m)
        key = XK_Caps_Lock;
    else if(NSEventModifierFlagHelp == m)
        key = XK_F1;
    
    if (key != 0) {
        [self sendKeyCode:key pressed:pressed];
    }
}

/* ----------------- VNCConnectionDelegate ----------------- */

- (void)connection:(VNCConnection *)conn stateDidChange:(VNCConnectionState *)connectionState
{
    if (connectionState.status == VNCConnectionStatusDisconnected) {
        NSString *reason = connectionState.error ? [connectionState.error localizedDescription] : NSLocalizedString(@"Disconnected", nil);
        [self terminateConnection:reason];
    } else if (connectionState.status == VNCConnectionStatusConnected) {
        [self sendPasteboardToServer:[NSPasteboard generalPasteboard]];
    }
}

- (void)connection:(VNCConnection *)conn
     credentialFor:(VNCAuthenticationType)authenticationType
        completion:(void (^)(VNCCredential *))completion
{
    BOOL requiresUsername = [VNCAuthenticationTypeUtils authenticationTypeRequiresUsername:authenticationType];
    BOOL requiresPassword = [VNCAuthenticationTypeUtils authenticationTypeRequiresPassword:authenticationType];
    
    if (requiresUsername) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setMessageText:NSLocalizedString(@"AuthenticationRequired", nil)];
            [alert setInformativeText:[NSString stringWithFormat:@"Connecting to %@", [[self server] name]]];
            [alert addButtonWithTitle:NSLocalizedString(@"Connect", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

            NSView *accessoryView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 60)] autorelease];
            
            NSTextField *usernameField = [[[NSTextField alloc] initWithFrame:NSMakeRect(80, 32, 200, 22)] autorelease];
            NSTextField *passwordField = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(80, 0, 200, 22)] autorelease];
            
            NSTextField *usernameLabel = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 32, 75, 22)] autorelease];
            [usernameLabel setStringValue:NSLocalizedString(@"Username:", nil)];
            [usernameLabel setBezeled:NO];
            [usernameLabel setDrawsBackground:NO];
            [usernameLabel setEditable:NO];
            [usernameLabel setSelectable:NO];
            [usernameLabel setAlignment:NSTextAlignmentRight];
            
            NSTextField *passwordLabel = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 75, 22)] autorelease];
            [passwordLabel setStringValue:NSLocalizedString(@"Password:", nil)];
            [passwordLabel setBezeled:NO];
            [passwordLabel setDrawsBackground:NO];
            [passwordLabel setEditable:NO];
            [passwordLabel setSelectable:NO];
            [passwordLabel setAlignment:NSTextAlignmentRight];
            
            [usernameField setStringValue:NSUserName()];
            if (password && [password length] > 0) {
                [passwordField setStringValue:password];
            }
            
            [accessoryView addSubview:usernameLabel];
            [accessoryView addSubview:usernameField];
            [accessoryView addSubview:passwordLabel];
            [accessoryView addSubview:passwordField];
            
            [alert setAccessoryView:accessoryView];
            
            NSModalResponse returnCode = [alert runModal];
            if (returnCode == NSAlertFirstButtonReturn) {
                NSString *user = [usernameField stringValue];
                NSString *pass = [passwordField stringValue];
                
                if (pass && [pass length] > 0) {
                    [password release];
                    password = [pass retain];
                }
                
                VNCCredential *cred = (id)[[VNCUsernamePasswordCredential alloc] initWithUsername:user password:pass];
                completion(cred);
                [cred release];
            } else {
                completion(nil);
            }
        });
        return;
    }
    
    if (requiresPassword) {
        if (password && [password length] > 0) {
            VNCCredential *cred = nil;
            if (requiresUsername) {
                cred = (id)[[VNCUsernamePasswordCredential alloc] initWithUsername:NSUserName() password:password];
            } else {
                cred = (id)[[VNCPasswordCredential alloc] initWithPassword:password];
            }
            completion(cred);
            [cred release];
        } else {
            if (authCompletion) {
                [authCompletion release];
            }
            authCompletion = [completion copy];
            pendingAuthType = (int)authenticationType;
            [self promptForPassword];
        }
    } else if (requiresUsername) {
        VNCCredential *cred = (id)[[VNCUsernamePasswordCredential alloc] initWithUsername:NSUserName() password:@""];
        completion(cred);
        [cred release];
    } else {
        completion(nil);
    }
}

- (void)connection:(VNCConnection *)conn didCreateFramebuffer:(VNCFramebuffer *)framebuffer
{
    // VNCCAFramebufferView (and all AppKit view creation) must happen on the main thread.
    // RoyalVNCKit calls this delegate on a Swift concurrency background thread.
    NSSize size = NSMakeSize(framebuffer.size.width, framebuffer.size.height);
    VNCFramebuffer *fb = framebuffer; // captured for block
    VNCConnection *c = conn;
    dispatch_sync(dispatch_get_main_queue(), ^{
        VNCCAFramebufferView *vncView = [[VNCCAFramebufferView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                                                        framebuffer:fb
                                                                         connection:c
                                                                 connectionDelegate:self];
        [session setRfbView:vncView];
        [self setRfbView:vncView];
        [session setSize:size];
        [session setupWindow];
        NSString *dispName = c.desktopName ? c.desktopName : [[self server] name];
        [session setDisplayName:dispName];
        [vncView release];
    });
}

- (void)connection:(VNCConnection *)conn didResizeFramebuffer:(VNCFramebuffer *)framebuffer
{
    NSSize size = NSMakeSize(framebuffer.size.width, framebuffer.size.height);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [session setSize:size];
        [session resize:size];
    });
}

- (void)connection:(VNCConnection *)conn didUpdateFramebuffer:(VNCFramebuffer *)framebuffer x:(uint16_t)x y:(uint16_t)y width:(uint16_t)width height:(uint16_t)height
{
    // Drawing is handled automatically by VNCCAFramebufferView
}

- (void)connection:(VNCConnection *)conn didUpdateCursor:(VNCCursor *)cursor
{
    // Cursor updates are handled automatically by VNCCAFramebufferView
}

/* ----------------- Getters/Setters ----------------- */

- (Profile*)profile
{
    return _profile;
}

- (NSString*)password
{
    return password;
}

- (Session *)session
{
    return session;
}

- (SshTunnel *)sshTunnel
{
    return sshTunnel;
}

- (BOOL)viewOnly
{
    return [server_ viewOnly];
}

- (id)eventFilter
{
    return _eventFilter;
}

- (NSString *)infoString
{
    return @"RoyalVNC Connection";
}

- (NSString *)statisticsString
{
    return @"Active";
}

- (void)setFrameBufferUpdateSeconds:(float)seconds
{
    // No-op — RoyalVNCKit manages its own update cadence
}

- (void)installMouseMovedTrackingRect
{
    // No-op
}

- (void)removeMouseMovedTrackingRect
{
    // No-op
}

- (void)writeBuffer
{
    // No-op — RoyalVNCKit sends input events immediately, no write buffer needed
}

- (void)requestFrameBufferUpdate:(id)sender
{
    // No-op — RoyalVNCKit handles frame update requests internally
}

- (void)forceFrameBufferUpdate
{
    // No-op — RoyalVNCKit manages framebuffer refresh automatically
}

- (void)writeSetDesktopSize:(NSSize)size
{
    [connection setDesktopSizeWithWidth:(uint16_t)size.width height:(uint16_t)size.height];
}

@end
