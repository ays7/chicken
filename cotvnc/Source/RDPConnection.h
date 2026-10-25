//
//  RDPConnection.h
//  Chicken
//
//  Created for Chicken Fork RDP integration.
//

#import <Cocoa/Cocoa.h>
#import "RemoteConnection.h"
#import "IServerData.h"

@class EventFilter;
@class RDPFrameBuffer;
@class Session;
@class RFBView;
@class SshTunnel;

@interface RDPConnection : NSObject <RemoteConnection>
{
    id<IServerData> server_;
    Session *session;
    RFBView *rfbView;
    RDPFrameBuffer *frameBuffer;
    EventFilter *_eventFilter;
    SshTunnel *sshTunnel;
    NSString *password;
    NSString *username;
    NSFileHandle *socketHandler;

    void *freerdpInstance;
    void *freerdpContext;
    void *dispContext;
    void *cliprdrContext;

@public
    BOOL dispReady;
    BOOL cliprdrReady;

@protected
    NSThread *workerThread;
    BOOL isConnected;
    BOOL shouldStop;
    void *stopEvent;

    unsigned int _pressedButtons;
    NSSize currentDesktopSize;
}

- (id)initWithFileHandle:(NSFileHandle *)file server:(id<IServerData>)server;
- (id)initWithServer:(id<IServerData>)server sshTunnel:(SshTunnel *)tunnel;
- (Session *)session;

- (void)notifyDirtyRect:(NSRect)rect;
- (void)notifyDesktopResize:(NSSize)newSize;
- (void)notifyConnected;
- (void)notifyDisconnected:(NSString *)reason;
- (void)notifyServerCursor:(NSCursor *)cursor;

@end
