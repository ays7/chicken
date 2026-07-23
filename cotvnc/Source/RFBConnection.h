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

#import <AppKit/AppKit.h>
#import "rfbproto.h"
#import "IServerData.h"

@class Session;
@class SshTunnel;
@class Profile;
@class VNCConnection;
@class VNCCAFramebufferView;
@class VNCCredential;
@class EventFilter;
@class EventFilterViewDelegate;

#define RFB_HOST		@"Host"
#define RFB_PASSWORD		@"Password"
#define RFB_REMEMBER		@"RememberPassword"
#define RFB_DISPLAY		@"Display"
#define RFB_SHARED		@"Shared"

#define RFB_PORT		5900

#define	DEFAULT_HOST	@"localhost"

#define NUM_BUTTON_EMU_KEYS	2

// jason added the following constants for fullscreen display
#define kTrackingRectThickness		10.0
#define kAutoscrollInterval			0.05

@interface RFBConnection : NSObject
{
    Session     *session;
    VNCCAFramebufferView *rfbView;
    VNCConnection *connection;
    id<IServerData> server_;
    NSString        *password;

    SshTunnel   *sshTunnel;
    Profile *_profile;
    
    void (^authCompletion)(VNCCredential *);
    int pendingAuthType;
    
    NSString *resolvedHost_;
    int resolvedPort_;
    
    EventFilter *_eventFilter;
    EventFilterViewDelegate *_eventFilterDelegate;
}

- (id)initWithFileHandle:(NSFileHandle*)file server:(id<IServerData>)server;
- (id)initWithFileHandle:(NSFileHandle*)file server:(id<IServerData>)server host:(NSString *)resolvedHost port:(int)resolvedPort;

- (void)dealloc;

- (void)closeConnection;
- (id<IServerData>)server;

- (void)setRfbView:(VNCCAFramebufferView *)view;
- (void)setSession:(Session *)aSession;
- (void)setPassword:(NSString *)password;
- (void)setSshTunnel:(SshTunnel *)tunnel;

- (BOOL)pasteFromPasteboard:(NSPasteboard*)pb;
- (void)sendPasteboardToServer:(NSPasteboard *)pb;
- (BOOL)serverSupportsSetDesktopSize;
- (void)terminateConnection:(NSString*)aReason;
- (void)authenticationFailed:(NSString *)aReason;
- (void)promptForPassword;

- (void)mouseClickedAt:(NSPoint)thePoint buttons:(unsigned int)mask;
- (void)mouseAt:(NSPoint)thePoint buttons:(unsigned int)mask;
- (void)sendKey:(unichar)key pressed:(BOOL)pressed;
- (void)sendModifier:(unsigned int)m pressed:(BOOL)pressed;
- (void)sendKeyCode:(CARD32)key pressed:(BOOL)pressed;

- (Profile*)profile;
- (NSString*)password;
- (Session *)session;
- (SshTunnel *)sshTunnel;
- (BOOL)viewOnly;

- (id)eventFilter;
- (NSString *)infoString;
- (NSString *)statisticsString;
- (void)setFrameBufferUpdateSeconds:(float)seconds;
- (void)installMouseMovedTrackingRect;
- (void)removeMouseMovedTrackingRect;
- (void)writeBuffer;
- (void)requestFrameBufferUpdate:(id)sender;
- (void)forceFrameBufferUpdate;
- (void)writeSetDesktopSize:(NSSize)size;

@end
