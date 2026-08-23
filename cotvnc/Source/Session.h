/* Copyright (C) 1998-2000  Helmut Maierhofer <helmut.maierhofer@chello.at>
 * Copyright 2011 Dustin Cartwright
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

#import <AppKit/AppKit.h>
#import "ConnectionWaiter.h"

@protocol IServerData;

@class RFBConnection;
@class RFBView;
@class SshTunnel;

@interface Session : NSObject <
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
NSNetServiceDelegate,NSWindowDelegate,
#endif
ConnectionWaiterDelegate>
{
    RFBConnection   *connection;
    IBOutlet RFBView *rfbView;
    IBOutlet NSWindow    *window;
    id<IServerData> server_;
    NSString        *username;
    NSString        *password;
    SshTunnel       *sshTunnel;

    id      scrollView;
    id      newTitleField;
    IBOutlet NSPanel *newTitlePanel;
    NSString    *titleString;
    id      statisticField;

    NSSize _maxSize;

    BOOL	horizontalScroll;
    BOOL	verticalScroll;

    id optionPanel;
    id infoField;

    NSString *realDisplayName;
    NSString *host;

    IBOutlet NSPanel *passwordSheet;
    IBOutlet NSTextField *passwordField;
    IBOutlet NSTextField *authHeader;
    IBOutlet NSTextField *authMessage;
    IBOutlet NSButton *rememberNewPassword;

        // for reconnection attempts
    IBOutlet NSPanel                *_reconnectPanel;
    IBOutlet NSProgressIndicator    *_reconnectIndicator;
    IBOutlet NSTextField            *_reconnectReason;
    NSDate                          *_connectionStartDate;
    NSTimer                         *_reconnectSheetTimer;
    ConnectionWaiter                *_reconnectWaiter;
    NSArray                         *_nibTopLevelObjects;
}

- (id)initWithConnection:(RFBConnection*)conn;
- (void)dealloc;

- (BOOL)viewOnly;
- (BOOL)isConnected;

- (void)setSize:(NSSize)size;
- (void)setDisplayName:(NSString *)aName;
- (void)setupWindow;
- (NSWindow *)window;
- (NSString *)titleString;
- (id<IServerData>)server;
- (NSString *)serverProfileName;
- (void)frameBufferUpdateComplete;
- (void)resize:(NSSize)size;

- (void)paste:(id)sender;
- (IBAction)sendPasteboardToServer:(id)sender;
- (void)terminateConnection:(NSString*)aReason;
- (void)authenticationFailed:(NSString *)aReason;
- (void)promptForPassword;
- (void)promptForUsernameAndPassword;
- (IBAction)reconnectWithNewPassword:(id)sender;
- (IBAction)dontReconnect:(id)sender;
- (IBAction)forceReconnect:(id)sender;
- (void)openNewTitlePanel:(id)sender;
- (void)setNewTitle:(id)sender;

- (IBAction)requestFrameBufferUpdate:(id)sender;

    //window delegate messages
- (void)windowDidBecomeKey:(NSNotification *)aNotification;
- (void)windowDidResignKey:(NSNotification *)aNotification;
- (void)windowDidDeminiaturize:(NSNotification *)aNotification;
- (void)windowDidMiniaturize:(NSNotification *)aNotification;
- (void)windowWillClose:(NSNotification *)aNotification;
- (void)windowDidResize:(NSNotification *)aNotification;

- (RFBConnection *)connection;

@end
