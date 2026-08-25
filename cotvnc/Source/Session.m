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
#import "RFBView.h"
#import "SshWaiter.h"
#import "TouchBarController.h"
#define XK_MISCELLANY
#include "keysymdef.h"

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



    NSArray *tlo = nil;
    [NSBundle.mainBundle loadNibNamed:@"RFBConnection" owner:self topLevelObjects:&tlo];
    for (id obj in tlo) {
        if ([obj isKindOfClass:[NSWindow class]]) {
            NSWindow *win = (NSWindow *)obj;
            [win setReleasedWhenClosed:NO];
            if ([win respondsToSelector:@selector(setTabbingMode:)]) {
                [win setTabbingMode:NSWindowTabbingModeDisallowed];
            }
        }
    }
    _nibTopLevelObjects = [tlo retain];
    [rfbView registerForDraggedTypes:[NSArray arrayWithObjects:NSPasteboardTypeString, NSPasteboardTypeFileURL, nil]];

    password = [[connection password] retain];

    _reconnectWaiter = nil;
    _reconnectSheetTimer = nil;



    /* On 10.7 Lion, the overlay scrollbars don't reappear properly on hover.
     * So, for now, we're going to force legacy scrollbars. */
    if ([scrollView respondsToSelector:@selector(setScrollerStyle:)])
        [scrollView setScrollerStyle:NSScrollerStyleLegacy];

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


    [connection closeConnection];
    [connection release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

	[titleString release];
	[(id)server_ release];
	[host release];
    [username release];
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
    [_nibTopLevelObjects release];
    [super dealloc];
}

- (BOOL)viewOnly
{
    return [server_ viewOnly];
}

- (BOOL)isConnected
{
    return (connection != nil && window != nil);
}

- (NSWindow *)window
{
    return window;
}

- (RFBConnection *)connection
{
    return connection;
}

- (NSString *)titleString
{
    return titleString ? titleString : [window title];
}

- (id<IServerData>)server
{
    return server_;
}

- (NSString *)serverProfileName
{
    if (server_) {
        NSString *sName = [server_ name];
        if (sName && [sName length] > 0) {
            return sName;
        }
    }
    return nil;
}

/* Begin a reconnection attempt to the server. */
- (void)beginReconnect
{
    if (sshTunnel && [sshTunnel isAlive]) {
        /* Reuse the same SSH tunnel if we have one and it is still alive. */
        _reconnectWaiter = [[SshWaiter alloc] initWithServer:server_
                                                    delegate:self
                                                      window:window
                                                   sshTunnel:sshTunnel];
    } else {
        [sshTunnel close];
        [sshTunnel release];
        sshTunnel = nil;
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

static inline NSSize FrameSizeForContentSize(NSSize cSize, BOOL hasH, BOOL hasV)
{
    return [NSScrollView frameSizeForContentSize:cSize
                          horizontalScrollerClass:hasH ? [NSScroller class] : nil
                            verticalScrollerClass:hasV ? [NSScroller class] : nil
                                       borderType:NSNoBorder
                                      controlSize:NSControlSizeRegular
                                    scrollerStyle:NSScrollerStyleLegacy];
}

- (void)connectionTerminatedSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	/* One might reasonably argue that this should be handled by the connection manager. */
	switch (returnCode) {
		case NSAlertFirstButtonReturn:
			break;
		case NSAlertSecondButtonReturn:
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
    [sshTunnel release];
    sshTunnel = nil;
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
            [passwordSheet.sheetParent endSheet:passwordSheet];

            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:NSLocalizedString(@"ConnectionTerminated", nil)];
            [alert setInformativeText:aReason ? aReason : @""];
            [alert addButtonWithTitle:NSLocalizedString(@"Okay", nil)];
            [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
                [self connectionTerminatedSheetDidEnd:window returnCode:(int)returnCode contextInfo:nil];
                [alert release];
            }];
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
				NSAlert *alert = [[NSAlert alloc] init];
				[alert setMessageText:header];
				[alert setInformativeText:aReason];
				[alert addButtonWithTitle:okayButton];
				if (supportReconnect) {
					[alert addButtonWithTitle:reconnectButton];
				}
				[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
					[self connectionTerminatedSheetDidEnd:window returnCode:(int)returnCode contextInfo:nil];
					[alert release];
				}];
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
    NSTextField *usernameField = [[passwordSheet contentView] viewWithTag:9999];
    NSTextField *usernameLabel = [[passwordSheet contentView] viewWithTag:9998];
    if (usernameField) {
        [usernameField setHidden:YES];
        [usernameLabel setHidden:YES];
    }

    [authHeader setStringValue:NSLocalizedString(@"AuthenticationRequired",
            nil)];
    [authMessage setStringValue:@""];
    [[passwordSheet defaultButtonCell] setTitle:NSLocalizedString(@"Connect",
            nil)];
    [self displayPasswordSheet];
}

- (void)promptForUsernameAndPassword
{
    NSTextField *usernameField = [[passwordSheet contentView] viewWithTag:9999];
    NSTextField *usernameLabel = [[passwordSheet contentView] viewWithTag:9998];
    if (!usernameField) {
        usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(17, 120, 156, 17)];
        [usernameLabel setTag:9998];
        [usernameLabel setStringValue:NSLocalizedString(@"Username:", nil)];
        [usernameLabel setEditable:NO];
        [usernameLabel setBordered:NO];
        [usernameLabel setDrawsBackground:NO];
        [[usernameLabel cell] setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
        [[passwordSheet contentView] addSubview:usernameLabel];
        [usernameLabel release];

        usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(185, 117, 205, 22)];
        [usernameField setTag:9999];
        [[usernameField cell] setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
        [[usernameField cell] setScrollable:YES];
        [[usernameField cell] setUsesSingleLineMode:YES];
        [[passwordSheet contentView] addSubview:usernameField];
        [usernameField release];
    }

    [usernameField setHidden:NO];
    [usernameLabel setHidden:NO];

    NSString *defaultUser = [server_ respondsToSelector:@selector(sshUser)] ? [server_ sshUser] : nil;
    if (!defaultUser || [defaultUser length] == 0) {
        defaultUser = NSUserName();
    }
    [usernameField setStringValue:defaultUser];

    [authHeader setStringValue:NSLocalizedString(@"AuthenticationRequired", nil)];
    [authMessage setStringValue:@""];
    [[passwordSheet defaultButtonCell] setTitle:NSLocalizedString(@"Connect", nil)];
    [self displayPasswordSheet];
}

- (void)displayPasswordSheet
{
    if ([server_ respondsToSelector:@selector(setRememberPassword:)])
        [rememberNewPassword setState: [server_ rememberPassword]];
    else
        [rememberNewPassword setHidden:YES];
    [window beginSheet:passwordSheet completionHandler:^(NSModalResponse returnCode) {
        [passwordSheet orderOut:self];
    }];
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

    NSTextField *usernameField = [[passwordSheet contentView] viewWithTag:9999];
    if (usernameField && ![usernameField isHidden]) {
        NSString *enteredUsername = [usernameField stringValue];
        [username release];
        username = [enteredUsername copy];
        if (connection) {
            [connection setUsername:username];
        }
    }

    [_reconnectReason setStringValue:@""];
    if (connection)
        [connection setPassword:password];
    else
        [self beginReconnect];
    [passwordSheet.sheetParent endSheet:passwordSheet];
}

/* User cancelled chance to enter new password */
- (IBAction)dontReconnect:(id)sender
{
    [passwordSheet.sheetParent endSheet:passwordSheet];
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

    maxviewsize = FrameSizeForContentSize([rfbView frame].size, horizontalScroll, verticalScroll);
    if(aSize.width < maxviewsize.width) {
        horizontalScroll = YES;
    }
    if(aSize.height < maxviewsize.height) {
        verticalScroll = YES;
    }
    maxviewsize = FrameSizeForContentSize([rfbView frame].size, horizontalScroll, verticalScroll);
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

	screenRect = [[NSScreen mainScreen] visibleFrame];
    wf.origin.x = wf.origin.y = 0;
    wf.size = FrameSizeForContentSize(_maxSize, NO, NO);
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



	contentView = (NSClipView *)[scrollView contentView];
    NSPoint scrollPt = NSMakePoint(0.0, _maxSize.height - [scrollView contentSize].height);
    NSRect targetBounds = NSMakeRect(scrollPt.x, scrollPt.y, [contentView bounds].size.width, [contentView bounds].size.height);
    [contentView scrollToPoint: [contentView constrainBoundsRect: targetBounds].origin];
    [scrollView reflectScrolledClipView: contentView];

    if ([window respondsToSelector:@selector(setTabbingMode:)]) {
        [window setTabbingMode:NSWindowTabbingModeDisallowed];
    }
    [window setCollectionBehavior:[window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];

    // If currently viewing a fullscreen space, switch to the default desktop workspace
    BOOL isAnyFullScreen = NO;
    for (Session *s in [[RFBConnectionManager sharedManager] sessions]) {
        if (s != self && [s isConnected] && (([[s window] styleMask] & NSWindowStyleMaskFullScreen) != 0)) {
            isAnyFullScreen = YES;
            break;
        }
    }
    if (!isAnyFullScreen && [NSApp keyWindow] && (([[NSApp keyWindow] styleMask] & NSWindowStyleMaskFullScreen) != 0)) {
        isAnyFullScreen = YES;
    }

    if (isAnyFullScreen) {
        NSWindow *cmWin = [[RFBConnectionManager sharedManager] window];
        if (cmWin) {
            [cmWin makeKeyAndOrderFront:nil];
        }
    }

    [window setTouchBar:[[TouchBarController sharedController] makeTouchBar]];
    [window makeFirstResponder:rfbView];
	[self windowDidResize: nil];
    [window makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
    [window display];

    if (isAnyFullScreen) {
        NSWindow *cmWin = [[RFBConnectionManager sharedManager] window];
        if (cmWin) {
            [cmWin orderOut:nil];
        }
    }
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

- (void)frameBufferUpdateComplete
{
    if ([optionPanel isVisible])
        [statisticField setStringValue:[connection statisticsString]];
}

- (void)resize:(NSSize)size
{
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
    if ([connection serverSupportsSetDesktopSize] && ![self viewOnly]) {
        // update the server with the new desktop size
        [connection writeSetDesktopSize:[[window contentView] frame].size];
        return;
    }

	[scrollView setHasHorizontalScroller:horizontalScroll];
	[scrollView setHasVerticalScroller:verticalScroll];
}

- (void)windowDidBecomeKey:(NSNotification *)aNotification
{

    
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

- (void)setFrameBufferUpdateSeconds:(float)seconds
{
    [connection setFrameBufferUpdateSeconds:seconds];
}

- (void)windowDidMiniaturize:(NSNotification *)aNotification
{
}

- (void)windowDidDeminiaturize:(NSNotification *)aNotification
{
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
    [window beginSheet:_reconnectPanel completionHandler:^(NSModalResponse returnCode) {
        [_reconnectPanel orderOut:self];
    }];
    [_reconnectIndicator startAnimation:self];

    [_reconnectSheetTimer release];
    _reconnectSheetTimer = nil;
}

- (void)reconnectCancelled:(id)sender
{
    [_reconnectWaiter cancel];
    [_reconnectWaiter release];
    _reconnectWaiter = nil;
    [_reconnectPanel.sheetParent endSheet:_reconnectPanel];
    [self endSession];
}

- (void)reconnectEnded:(id)sender returnCode:(int)retCode
           contextInfo:(void *)info
{
    [_reconnectPanel orderOut:self];
}

- (void)connectionPrepareForSheet
{
    [_reconnectPanel.sheetParent endSheet:_reconnectPanel];
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
    [sshTunnel close];
    [sshTunnel release];
    sshTunnel = nil;
    [self endSession];
}

/* Reconnect attempt has succeeded */
- (void)connectionSucceeded:(RFBConnection *)newConnection
{
    [_reconnectPanel.sheetParent endSheet:_reconnectPanel];
    [_reconnectSheetTimer invalidate];
    [_reconnectSheetTimer release];
    _reconnectSheetTimer = nil;



    connection = [newConnection retain];
    [connection setSession:self];
    [connection setRfbView:rfbView];
    if (username)
        [connection setUsername:username];
    [connection setPassword:password];
    [connection installMouseMovedTrackingRect];
    [sshTunnel release];
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
