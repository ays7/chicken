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

#import "Session.h"
#import "AppDelegate.h"
#import "IServerData.h"

#import "KeyEquivalent.h"
#import "KeyEquivalentManager.h"
#import "KeyEquivalentScenario.h"
#import "PrefController.h"
#import "ProfileManager.h"
#import "RFBConnection.h"
#import "RFBConnectionManager.h"
#import "SshWaiter.h"
#define XK_MISCELLANY
#include "keysymdef.h"

@interface NSView (ChickenTint)
- (void)setTint:(NSColor *)tint;
@end

@implementation NSView (ChickenTint)
- (void)setTint:(NSColor *)tint {
    // No-op
}
@end

#if MAC_OS_X_VERSION_MAX_ALLOWED < 1050
@interface NSAlert(AvailableInLeopard)
    - (void)setShowsSuppressionButton:(BOOL)flag;
    - (NSButton *)suppressionButton;
@end
#endif

/* Ah, the joy of supporting 4 different releases of the OS */
#if MAC_OS_X_VERSION_MAX_ALLOWED < 1070
#if MAC_OS_X_VERSION_MAX_ALLOWED < 1050
#if __LP64__
typedef long NSInteger;
#else
typedef int NSInteger;
#endif
#endif

@interface NSScrollView(AvailableInLion)
    - (void)setScrollerStyle:(NSInteger)newScrollerStyle;
@end

enum {
    NSScrollerStyleLegacy = 0,
    NSScrollerStyleOverlay = 1
};
#endif

@interface Session(Private)

- (void)startTimerForReconnectSheet;

- (void)displayPasswordSheet;

@end

@implementation Session

- (id)initWithConnection:(RFBConnection *)aConnection
{
    if ((self = [super init]) == nil)
        return nil;

    connection = [aConnection retain];
    server_ = [[connection server] retain];
    host = [[server_ host] retain];
    sshTunnel = [[connection sshTunnel] retain];



    [NSBundle loadNibNamed:@"RFBConnection" owner:self];
    [rfbView registerForDraggedTypes:[NSArray arrayWithObjects:NSPasteboardTypeString, NSFilenamesPboardType, nil]];

    password = [[connection password] retain];

    _reconnectWaiter = nil;
    _reconnectSheetTimer = nil;



    /* On 10.7 Lion, the overlay scrollbars don't reappear properly on hover.
     * So, for now, we're going to force legacy scrollbars. */
    if ([scrollView respondsToSelector:@selector(setScrollerStyle:)])
        [scrollView setScrollerStyle:NSScrollerStyleLegacy];
    [scrollView setWantsLayer:YES];
    [[scrollView contentView] setWantsLayer:YES];

    _connectionStartDate = [[NSDate alloc] init];

    [connection setSession:self];
    [connection setRfbView:rfbView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tintChanged:)
                                                 name:ProfileTintChangedMsg
                                               object:[connection profile]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidChangeOcclusionState:)
                                                 name:NSWindowDidChangeOcclusionStateNotification
                                               object:nil];

    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [connection setSession:nil];
    [connection closeConnection];
    [connection release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

	[titleString release];
	[(id)server_ release];
	[host release];
    [password release];
    [sshTunnel close];
    [sshTunnel release];
	[realDisplayName release];
    [_reconnectSheetTimer invalidate];
    [_reconnectSheetTimer release];
    [_reconnectWaiter cancel];
    [_reconnectWaiter release];

	[newTitlePanel orderOut:self];
	[optionPanel orderOut:self];
	
	[window setDelegate:nil];
	[window close];

    [_connectionStartDate release];
    [super dealloc];
}

- (BOOL)viewOnly
{
    return [server_ viewOnly];
}

/* Begin a reconnection attempt to the server. */
- (void)beginReconnect
{
    if (sshTunnel) {
        /* Reuse the same SSH tunnel if we have one. */
        _reconnectWaiter = [[SshWaiter alloc] initWithServer:server_
                                                    delegate:self
                                                      window:window
                                                   sshTunnel:sshTunnel];
    } else {
        _reconnectWaiter = [[ConnectionWaiter waiterForServer:server_
                                                     delegate:self
                                                       window:window] retain];
    }
    NSString *templ = NSLocalizedString(@"NoReconnection", nil);
    NSString *err = [NSString stringWithFormat:templ, host];
    [_reconnectWaiter setErrorStr:err];
    [self startTimerForReconnectSheet];
}

- (void)startTimerForReconnectSheet
{
    _reconnectSheetTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
            target:self selector:@selector(createReconnectSheet:)
            userInfo:nil repeats:NO] retain];
}

- (void)connectionTerminatedSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	/* One might reasonably argue that this should be handled by the connection manager. */
	switch (returnCode) {
		case NSAlertDefaultReturn:
			break;
		case NSAlertAlternateReturn:
            [self beginReconnect];
            return;
		default:
			NSLog(@"Unknown alert returnvalue: %d", returnCode);
			break;
	}
    [[RFBConnectionManager sharedManager] removeConnection:self];
}

- (void)connectionProblem
{
    [connection closeConnection];
    [connection release];
    connection = nil;
}

- (void)endSession
{
    [sshTunnel close];
    [[RFBConnectionManager sharedManager] removeConnection:self];
}

/* Some kind of connection failure. Decide whether to try to reconnect. */
- (void)terminateConnection:(NSString*)aReason
{
    if (!connection)
        return;

    [self connectionProblem];

    if ([passwordSheet isVisible]) {
        /* User is in middle of entering password. */
        if ([server_ doYouSupport:CONNECT]) {
            NSLog(@"Will reconnect to server when password entered. Reason for disconnect was: %@", aReason);
            return;
        } else {
            /* Server doesn't support reconnect, so we have to interrupt the
             * password sheet to show an error*/
            [NSApp endSheet:passwordSheet];

            NSBeginAlertSheet(NSLocalizedString(@"ConnectionTerminated", nil),
                    NSLocalizedString(@"Okay", nil), nil, nil, window, self,
                    @selector(connectionTerminatedSheetDidEnd:returnCode:contextInfo:),
                    nil, nil, @"%@", aReason);
        }
    } else {
        if(aReason) {
            NSTimeInterval timeout = [[PrefController sharedController] intervalBeforeReconnect];
            BOOL supportReconnect = [server_ doYouSupport:CONNECT];

            [_reconnectReason setStringValue:aReason];
			if (supportReconnect
                    && -[_connectionStartDate timeIntervalSinceNow] > timeout) {
                NSLog(@"Automatically reconnecting to server.  The connection was closed because: \"%@\".", aReason);
				// begin reconnect
                [self beginReconnect];
			}
			else {
				// Ask what to do
				NSString *header = NSLocalizedString( @"ConnectionTerminated", nil );
				NSString *okayButton = NSLocalizedString( @"Okay", nil );
				NSString *reconnectButton =  NSLocalizedString( @"Reconnect", nil );
				NSBeginAlertSheet(header, okayButton, supportReconnect ? reconnectButton : nil, nil, window, self, @selector(connectionTerminatedSheetDidEnd:returnCode:contextInfo:), nil, nil, @"%@", aReason);
			}
        } else {
            [[RFBConnectionManager sharedManager] removeConnection:self];
        }
    }
}

/* Authentication failed: give the user a chance to re-enter password. */
- (void)authenticationFailed:(NSString *)aReason
{
    if (connection == nil)
        return;

    if (![server_ doYouSupport:CONNECT])
        [self terminateConnection:NSLocalizedString(@"AuthenticationFailed", nil)];

    [self connectionProblem];
    [authHeader setStringValue:NSLocalizedString(@"AuthenticationFailed", nil)];
    [authMessage setStringValue: aReason];
    [[passwordSheet defaultButtonCell] setTitle:NSLocalizedString(@"Reconnect",
            nil)];
    [self displayPasswordSheet];
}

- (void)promptForPassword
{
    [authHeader setStringValue:NSLocalizedString(@"AuthenticationRequired",
            nil)];
    [authMessage setStringValue:@""];
    [[passwordSheet defaultButtonCell] setTitle:NSLocalizedString(@"Connect",
            nil)];
    [self displayPasswordSheet];
}

- (void)displayPasswordSheet
{
    if ([server_ respondsToSelector:@selector(setRememberPassword:)])
        [rememberNewPassword setState: [server_ rememberPassword]];
    else
        [rememberNewPassword setHidden:YES];
    [NSApp beginSheet:passwordSheet modalForWindow:window
           modalDelegate:self
           didEndSelector:@selector(passwordEnteredFor:returnCode:contextInfo:)
           contextInfo:nil];
}

/* User entered new password */
- (IBAction)reconnectWithNewPassword:(id)sender
{
    [password release];
    password = [[passwordField stringValue] retain];
    if ([rememberNewPassword state])
        [server_ setPassword: password];
    if ([server_ respondsToSelector:@selector(setRememberPassword:)]) {
        [server_ setRememberPassword: [rememberNewPassword state]];
        [[NSNotificationCenter defaultCenter] postNotificationName:ServerChangeMsg
                                                            object:server_];
    }

    [_reconnectReason setStringValue:@""];
    if (connection)
        [connection setPassword:password];
    else
        [self beginReconnect];
    [NSApp endSheet:passwordSheet];
}

/* User cancelled chance to enter new password */
- (IBAction)dontReconnect:(id)sender
{
    [NSApp endSheet:passwordSheet];
    [self connectionProblem];
    [self endSession];
}

- (void)passwordEnteredFor:(NSWindow *)wind returnCode:(int)retCode
            contextInfo:(void *)info
{
    [passwordSheet orderOut:self];
}

/* Close the connection and then reconnect */
- (IBAction)forceReconnect:(id)sender
{
    if (connection == nil)
        return;

    [self connectionProblem];
    [_reconnectReason setStringValue:@""];

    // Force ourselves to use a new SSH tunnel
    [sshTunnel close];
    [sshTunnel release];
    sshTunnel = nil;

    [self beginReconnect];
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item
{
    if ([item action] == @selector(forceReconnect:))
        // we only enable Force Reconnect menu item if server supports it
        return [server_ doYouSupport:CONNECT];
    else
        return [self respondsToSelector:[item action]];
}

- (void)setSize:(NSSize)aSize
{
    _maxSize = aSize;
}

/* Returns the maximum possible size for the window. Also, determines whether or
 * not the scrollbars are necessary. */
- (NSSize)_maxSizeForWindowSize:(NSSize)aSize;
{
    NSRect  winframe;
    NSSize	maxviewsize;
    BOOL serverSupportsResize = [connection serverSupportsSetDesktopSize];

    horizontalScroll = verticalScroll = NO;

    // If server supports SetDesktopSize, allow any window size without scrollbars
    if (serverSupportsResize && ![self viewOnly]) {
        return aSize;
    }

    maxviewsize = [NSScrollView frameSizeForContentSize:[rfbView frame].size
                                  hasHorizontalScroller:horizontalScroll
                                    hasVerticalScroller:verticalScroll
                                             borderType:NSNoBorder];
    if(aSize.width < maxviewsize.width) {
        horizontalScroll = YES;
    }
    if(aSize.height < maxviewsize.height) {
        verticalScroll = YES;
    }
    maxviewsize = [NSScrollView frameSizeForContentSize:[rfbView frame].size
                                  hasHorizontalScroller:horizontalScroll
                                    hasVerticalScroller:verticalScroll
                                             borderType:NSNoBorder];
    winframe = [window frame];
    winframe.size = maxviewsize;
    winframe = [NSWindow frameRectForContentRect:winframe styleMask:[window styleMask]];
    return winframe.size;
}

/* Sets up window. */
- (void)setupWindow
{
    NSRect wf;
	NSRect screenRect;
	NSClipView *contentView;
	NSString *serverName;

    [window setRestorable:NO];
	screenRect = [[NSScreen mainScreen] visibleFrame];
    wf.origin.x = wf.origin.y = 0;
    wf.size = [NSScrollView frameSizeForContentSize:_maxSize hasHorizontalScroller:NO hasVerticalScroller:NO borderType:NSNoBorder];
    wf = [NSWindow frameRectForContentRect:wf styleMask:[window styleMask]];
	if (NSWidth(wf) > NSWidth(screenRect)) {
		horizontalScroll = YES;
		wf.size.width = NSWidth(screenRect);
	}
	if (NSHeight(wf) > NSHeight(screenRect)) {
		verticalScroll = YES;
		wf.size.height = NSHeight(screenRect);
	}
	
	// According to the Human Interace Guidelines, new windows should be "visually centered"
	// If screenRect is X1,Y1-X2,Y2, and wf is x1,y1 -x2,y2, then
	// the origin (bottom left point of the rect) for wf should be
	// Ox = ((X2-X1)-(x2-x1)) * (1/2)    [I.e., one half screen width less window width]
	// Oy = ((Y2-Y1)-(y2-y1)) * (2/3)    [I.e., two thirds screen height less window height]
	// Then the origin must be offset by the "origin" of the screen rect.
	// Note that while Rects are floats, we seem to have an issue if the origin is
	// not an integer, so we use the floor() function.
	wf.origin.x = floor((NSWidth(screenRect) - NSWidth(wf))/2 + NSMinX(screenRect));
	wf.origin.y = floor((NSHeight(screenRect) - NSHeight(wf))*2/3 + NSMinY(screenRect));
	
    // :TOFIX: this doesn't work for unnamed servers
	serverName = [server_ name];
	if(![window setFrameUsingName:serverName]) {
		// NSLog(@"Window did NOT have an entry: %@\n", serverName);
		[window setFrame:wf display:NO];
	}
	[window setFrameAutosaveName:serverName];



	contentView = [scrollView contentView];
    [contentView scrollToPoint: [contentView constrainScrollPoint: NSMakePoint(0.0, _maxSize.height - [scrollView contentSize].height)]];
    [scrollView reflectScrolledClipView: contentView];

    [window makeFirstResponder:rfbView];
	[self windowDidResize: nil];
    [window makeKeyAndOrderFront:self];
}

- (void)setNewTitle:(id)sender
{
    [titleString release];
    titleString = [[newTitleField stringValue] retain];

    [[RFBConnectionManager sharedManager] setDisplayNameTranslation:titleString forName:realDisplayName forHost:host];
    [window setTitle:titleString];
    [newTitlePanel orderOut:self];
}

- (void)setDisplayName:(NSString*)aName
{
	[realDisplayName release];
    realDisplayName = [aName retain];
    [titleString release];
    titleString = [[[RFBConnectionManager sharedManager] translateDisplayName:realDisplayName forHost:host] retain];
    [window setTitle:titleString];
}

- (void)setRfbView:(NSView *)view
{
    rfbView = view;
    if (scrollView) {
        [scrollView setDocumentView:rfbView];
    }
}

- (void)frameBufferUpdateComplete
{
    if ([optionPanel isVisible])
        [statisticField setStringValue:[connection statisticsString]];
}

- (void)resize:(NSSize)size
{
    inServerResize = YES;

    BOOL serverSupportsResize = [connection serverSupportsSetDesktopSize];
    if (serverSupportsResize && ![self viewOnly]) {
        if (pendingClientResize) {
            // This resize was confirmed in response to a resize we requested.
            // The window is already the correct size (user dragged it to the
            // desired size). Resizing the window back to the server's integer
            // pixel size would cause sub-pixel mismatches on Retina / fractional-
            // scaling displays, leaving empty bands along the edges.
            //
            // Instead, fit the rfbView to exactly fill the current scroll view
            // content area so there are no gaps.
            pendingClientResize = NO;
            NSSize contentSize = [scrollView contentSize];
            [rfbView setFrameSize:contentSize];
        } else {
            // Server-initiated resize (e.g. server changed its own display
            // resolution). Resize the window to fit the new framebuffer.
            [rfbView setFrameSize:size];
            NSRect frame = [window frame];
            NSRect contentRect = NSMakeRect(0, 0, size.width, size.height);
            NSRect targetFrame = [window frameRectForContentRect:contentRect];

            // Preserve the top-left corner of the window when resizing
            targetFrame.origin.x = frame.origin.x;
            targetFrame.origin.y = frame.origin.y + frame.size.height - targetFrame.size.height;

            [window setFrame:targetFrame display:YES];
        }
        [self windowDidResize:nil];
    } else {
        [rfbView setFrameSize:size];
        NSSize  maxSize;
        NSRect  frame;

        // resize window, if necessary
        maxSize = [self _maxSizeForWindowSize:[[window contentView] frame].size];
        frame = [window frame];
        if (frame.size.width > maxSize.width)
            frame.size.width = maxSize.width;
        if (frame.size.height > maxSize.height)
            frame.size.height = maxSize.height;
        [window setFrame:frame display:YES];

        [self windowDidResize:nil]; // setup scroll bars if necessary
    }
    
    inServerResize = NO;
}

- (void)requestFrameBufferUpdate:(id)sender
{
    [connection requestFrameBufferUpdate:sender];
}

- (void)sendCmdOptEsc: (id)sender
{
    [connection sendKeyCode: XK_Alt_L pressed: YES];
    [connection sendKeyCode: XK_Meta_L pressed: YES];
    [connection sendKeyCode: XK_Escape pressed: YES];
    [connection sendKeyCode: XK_Escape pressed: NO];
    [connection sendKeyCode: XK_Meta_L pressed: NO];
    [connection sendKeyCode: XK_Alt_L pressed: NO];
    [connection writeBuffer];
}

- (void)sendCtrlAltDel: (id)sender
{
    [connection sendKeyCode: XK_Control_L pressed: YES];
    [connection sendKeyCode: XK_Alt_L pressed: YES];
    [connection sendKeyCode: XK_Delete pressed: YES];
    [connection sendKeyCode: XK_Delete pressed: NO];
    [connection sendKeyCode: XK_Alt_L pressed: NO];
    [connection sendKeyCode: XK_Control_L pressed: NO];
    [connection writeBuffer];
}

- (void)sendPauseKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Pause pressed: YES];
    [connection sendKeyCode: XK_Pause pressed: NO];
    [connection writeBuffer];
}

- (void)sendBreakKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Break pressed: YES];
    [connection sendKeyCode: XK_Break pressed: NO];
    [connection writeBuffer];
}

- (void)sendPrintKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Print pressed: YES];
    [connection sendKeyCode: XK_Print pressed: NO];
    [connection writeBuffer];
}

- (void)sendExecuteKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Execute pressed: YES];
    [connection sendKeyCode: XK_Execute pressed: NO];
    [connection writeBuffer];
}

- (void)sendInsertKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Insert pressed: YES];
    [connection sendKeyCode: XK_Insert pressed: NO];
    [connection writeBuffer];
}

- (void)sendDeleteKeyCode: (id)sender
{
    [connection sendKeyCode: XK_Delete pressed: YES];
    [connection sendKeyCode: XK_Delete pressed: NO];
    [connection writeBuffer];
}

- (void)paste:(id)sender
{
    [connection pasteFromPasteboard:[NSPasteboard generalPasteboard]];
}

- (void)sendPasteboardToServer:(id)sender
{
    [connection sendPasteboardToServer:[NSPasteboard generalPasteboard]];
}

/* --------------------------------------------------------------------------------- */
- (void)openNewTitlePanel:(id)sender
{
    [newTitleField setStringValue:titleString];
    [newTitlePanel makeKeyAndOrderFront:self];
}

/* --------------------------------------------------------------------------------- */
- (BOOL)hasKeyWindow
{
    return [window isKeyWindow];
}

/* Window delegate methods */

- (void)windowDidChangeOcclusionState:(NSNotification *)aNotification
{
    BOOL isVisible = ([window occlusionState] & NSWindowOcclusionStateVisible) != 0;
    BOOL isKey = [window isKeyWindow];
    
    if (isVisible) {
        // Window is visible, use appropriate update speed based on key state
        float s = isKey ? [[PrefController sharedController] frontFrameBufferUpdateSeconds]
                        : [[PrefController sharedController] otherFrameBufferUpdateSeconds];
        [connection setFrameBufferUpdateSeconds:s];
        
        if (isKey) {
            [connection installMouseMovedTrackingRect];
        }

        // sometimes when switching workspaces content gets grabled for some reason
        // see if content syncing helps....
        // Incremental update apparently doesn't work as expected, so we'll force an update
        [connection forceFrameBufferUpdate];
    } else {
        // Window is occluded/hidden, use maximum update interval to reduce CPU
        float s = [[PrefController sharedController] maxPossibleFrameBufferUpdateSeconds];
        [connection setFrameBufferUpdateSeconds:s];
        [connection removeMouseMovedTrackingRect];
    }
}

- (void)windowWillClose:(NSNotification *)aNotification
{
    // dealloc closes the window, so we have to null it out here
    // The window will autorelease itself when closed.  If we allow terminateConnection
    // to close it again, it will get double-autoreleased.  Bummer.
    [window setDelegate:nil];
    window = NULL;
    [self endSession];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize
{
    // If server supports SetDesktopSize, allow any window size
    if ([connection serverSupportsSetDesktopSize] && ![self viewOnly]) {
        
        // allow anything not outrageously small
        if (proposedFrameSize.width < 200)
            proposedFrameSize.width = 200;
        if (proposedFrameSize.height < 200)
            proposedFrameSize.height = 200;
        return proposedFrameSize;
    }

    NSSize max = [self _maxSizeForWindowSize:proposedFrameSize];

    max.width = (proposedFrameSize.width > max.width) ? max.width : proposedFrameSize.width;
    max.height = (proposedFrameSize.height > max.height) ? max.height : proposedFrameSize.height;
    return max;
}

- (void)windowDidResize:(NSNotification *)aNotification
{
    BOOL serverSupportsResize = [connection serverSupportsSetDesktopSize];

    if (!inServerResize && serverSupportsResize && ![self viewOnly]) {
        if ([window inLiveResize]) {
            // Defer resizing until live resize ends
            return;
        }
        // Snap to exact integer pixel count before sending to server.
        // scrollView contentSize may be fractional on Retina/non-integer-scaled displays;
        // writeSetDesktopSize truncates to uint16_t.  If we don't snap the window frame,
        // the view bounds will be fractional but framebufferSize will be integer, leaving
        // sub-pixel empty bands around the Metal layer.
        [self snapWindowToIntegerContentSize];
        pendingClientResize = YES;
        [connection writeSetDesktopSize:[scrollView contentSize]];
        return;
    }

    if (serverSupportsResize && ![self viewOnly]) {
        [scrollView setHasHorizontalScroller:NO];
        [scrollView setHasVerticalScroller:NO];
    } else {
        [scrollView setHasHorizontalScroller:horizontalScroll];
        [scrollView setHasVerticalScroller:verticalScroll];
    }
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
    if ([connection serverSupportsSetDesktopSize] && ![self viewOnly]) {
        // Snap to exact integer pixel count before sending to server (see windowDidResize:).
        [self snapWindowToIntegerContentSize];
        pendingClientResize = YES;
        [connection writeSetDesktopSize:[scrollView contentSize]];
    }
}

// Resize the window so that its content area is exactly floor(contentSize), eliminating
// sub-pixel fractions that would otherwise leave empty bands between the VNC view and the
// window edge after the server confirms the resize with integer pixel dimensions.
- (void)snapWindowToIntegerContentSize
{
    NSSize cs = [scrollView contentSize];
    NSSize intCS = NSMakeSize(floor(cs.width), floor(cs.height));
    if (NSEqualSizes(cs, intCS)) {
        return; // already integer
    }
    NSRect frame = [window frame];
    NSRect contentRect = [window contentRectForFrameRect:frame];
    NSRect intContentRect = NSMakeRect(contentRect.origin.x,
                                       contentRect.origin.y + (contentRect.size.height - intCS.height),
                                       intCS.width,
                                       intCS.height);
    NSRect newFrame = [window frameRectForContentRect:intContentRect];
    inServerResize = YES;
    [window setFrame:newFrame display:NO];
    inServerResize = NO;
}

- (void)windowDidBecomeKey:(NSNotification *)aNotification
{
    NSLog(@"[Chicken] windowDidBecomeKey called");
    
    // Only install mouse tracking and update frame rate if window is actually visible
    BOOL isVisible = ([window occlusionState] & NSWindowOcclusionStateVisible) != 0;
    if (isVisible) {
        [connection installMouseMovedTrackingRect];
        [connection setFrameBufferUpdateSeconds: [[PrefController sharedController] frontFrameBufferUpdateSeconds]];
    }
    
    [rfbView setTint:[[connection profile] tintWhenFront:YES]];
    
    // sync server clipboard automatically
    [connection sendPasteboardToServer:[NSPasteboard generalPasteboard]];
}

- (void)windowDidResignKey:(NSNotification *)aNotification
{
	[connection removeMouseMovedTrackingRect];
	
	// Only update frame rate if window is actually visible
	BOOL isVisible = ([window occlusionState] & NSWindowOcclusionStateVisible) != 0;
	if (isVisible) {
		[connection setFrameBufferUpdateSeconds: [[PrefController sharedController] otherFrameBufferUpdateSeconds]];
	}
	
    [rfbView setTint:[[connection profile] tintWhenFront:NO]];
	
	//Reset keyboard state on remote end
	[[connection eventFilter] clearAllEmulationStates];
}

- (void)tintChanged:(NSNotification *)notif
{
    [rfbView setTint:[[connection profile] tintWhenFront:[window isKeyWindow]]];
}

- (void)openOptions:(id)sender
{
    [infoField setStringValue: [connection infoString]];
    [statisticField setStringValue:[connection statisticsString]];
    [optionPanel setTitle:titleString];
    [optionPanel makeKeyAndOrderFront:self];
}



/* Reconnection attempts */

- (void)createReconnectSheet:(id)sender
{
    [NSApp beginSheet:_reconnectPanel modalForWindow:window
           modalDelegate:self
           didEndSelector:@selector(reconnectEnded:returnCode:contextInfo:)
           contextInfo:nil];
    [_reconnectIndicator startAnimation:self];

    [_reconnectSheetTimer release];
    _reconnectSheetTimer = nil;
}

- (void)reconnectCancelled:(id)sender
{
    [_reconnectWaiter cancel];
    [_reconnectWaiter release];
    _reconnectWaiter = nil;
    [NSApp endSheet:_reconnectPanel];
    [self endSession];
}

- (void)reconnectEnded:(id)sender returnCode:(int)retCode
           contextInfo:(void *)info
{
    [_reconnectPanel orderOut:self];
}

- (void)connectionPrepareForSheet
{
    [NSApp endSheet:_reconnectPanel];
    [_reconnectSheetTimer invalidate];
    [_reconnectSheetTimer release];
    _reconnectSheetTimer = nil;
}

- (void)connectionSheetOver
{
    [self startTimerForReconnectSheet];
}

/* Reconnect attempt has failed */
- (void)connectionFailed
{
    [self endSession];
}

/* Reconnect attempt has succeeded */
- (void)connectionSucceeded:(RFBConnection *)newConnection
{
    [NSApp endSheet:_reconnectPanel];
    [_reconnectSheetTimer invalidate];
    [_reconnectSheetTimer release];
    _reconnectSheetTimer = nil;



    connection = [newConnection retain];
    [connection setSession:self];
    [connection setRfbView:rfbView];
    [connection setPassword:password];
    [connection installMouseMovedTrackingRect];
    if (sshTunnel == nil)
        sshTunnel = [[connection sshTunnel] retain];

    [_connectionStartDate release];
    _connectionStartDate = [[NSDate alloc] init];

    [_reconnectWaiter release];
    _reconnectWaiter = nil;
}

- (IBAction)showProfileManager:(id)sender
{
    [[ProfileManager sharedManager] showWindowWithProfile:
        [[server_ profile] profileName]];
}

@end
