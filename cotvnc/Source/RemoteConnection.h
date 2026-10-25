//
//  RemoteConnection.h
//  Chicken
//
//  Created for Chicken Fork RDP integration.
//

#import <Cocoa/Cocoa.h>

@protocol IServerData;
@class EventFilter;
@class FrameBuffer;
@class Profile;
@class RFBView;
@class ServerBase;
@class Session;
@class SshTunnel;

@protocol RemoteConnection <NSObject>

- (id<IServerData>)server;
- (SshTunnel *)sshTunnel;
- (NSString *)password;
- (NSString *)username;
- (Profile *)profile;
- (EventFilter *)eventFilter;
- (BOOL)viewOnly;

- (Session *)session;
- (void)setSession:(Session *)session;
- (void)setRfbView:(RFBView *)view;
- (void)setUsername:(NSString *)username;
- (void)setPassword:(NSString *)password;
- (void)setSshTunnel:(SshTunnel *)tunnel;

- (void)closeConnection;
- (void)terminateConnection:(NSString *)aReason;

- (BOOL)serverSupportsSetDesktopSize;
- (void)writeSetDesktopSize:(NSSize)newSize;

- (NSString *)statisticsString;
- (NSString *)infoString;

- (void)requestFrameBufferUpdate:(id)sender;
- (void)forceFrameBufferUpdate;
- (void)setFrameBufferUpdateSeconds:(float)seconds;

- (void)installMouseMovedTrackingRect;
- (void)removeMouseMovedTrackingRect;
- (void)viewFrameDidChange:(NSNotification *)notification;

- (BOOL)pasteFromPasteboard:(NSPasteboard *)pasteboard;
- (void)sendPasteboardToServer:(NSPasteboard *)pasteboard;

- (void)mouseAt:(NSPoint)thePoint buttons:(unsigned int)mask;
- (void)mouseClickedAt:(NSPoint)thePoint buttons:(unsigned int)mask;
- (void)sendKey:(unichar)c pressed:(BOOL)pressed;
- (void)sendModifier:(unsigned int)m pressed:(BOOL)pressed;
- (void)sendKeyCode:(unsigned int)key pressed:(BOOL)pressed;
- (void)writeBuffer;

- (FrameBuffer *)frameBuffer;

@end
