//
//  RDPConnection.m
//  Chicken
//
//  Created for Chicken Fork RDP integration.
//

#import "RDPConnection.h"
#import "RDPFrameBuffer.h"
#import "Session.h"
#import "RFBView.h"
#import "EventFilter.h"
#import "SshTunnel.h"
#import "Profile.h"
#import "ProfileDataManager.h"
#import "PrefController.h"
#import "ServerBase.h"
#define XK_MISCELLANY
#include "keysymdef.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/graphics.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/event.h>
#include <winpr/synch.h>
#include <winpr/input.h>

struct rdp_chicken_context
{
    rdpClientContext common;
    void *connection; // __bridge void * to RDPConnection
    pEndPaint original_EndPaint;
    pDesktopResize original_DesktopResize;
};
typedef struct rdp_chicken_context rdpChickenContext;

struct rdp_chicken_pointer
{
    rdpPointer pointer;
    NSCursor *cursor;
};
typedef struct rdp_chicken_pointer rdpChickenPointer;

static BOOL rdp_client_global_init(void) { return TRUE; }
static void rdp_client_global_uninit(void) {}
static BOOL rdp_client_new(freerdp *instance, rdpContext *context) { return TRUE; }
static void rdp_client_free(freerdp *instance, rdpContext *context) {}
static int rdp_client_start(rdpContext *context) { return 0; }
static int rdp_client_stop(rdpContext *context) { return 0; }

static BOOL rdp_BeginPaint(rdpContext *context);
static BOOL rdp_EndPaint(rdpContext *context);
static BOOL rdp_DesktopResize(rdpContext *context);
static BOOL rdp_PreConnect(freerdp *instance);
static BOOL rdp_PostConnect(freerdp *instance);
static void rdp_PostDisconnect(freerdp *instance);
static DWORD rdp_VerifyCertificateEx(freerdp *instance, const char *host, UINT16 port,
                                     const char *common_name, const char *subject,
                                     const char *issuer, const char *fingerprint, DWORD flags);
static BOOL rdp_AuthenticateEx(freerdp *instance, char **username, char **password,
                               char **domain, rdp_auth_reason reason);

static BOOL rdp_Pointer_New(rdpContext *context, rdpPointer *pointer);
static void rdp_Pointer_Free(rdpContext *context, rdpPointer *pointer);
static BOOL rdp_Pointer_Set(rdpContext *context, rdpPointer *pointer);
static BOOL rdp_Pointer_SetNull(rdpContext *context);
static BOOL rdp_Pointer_SetDefault(rdpContext *context);
static BOOL rdp_Pointer_SetPosition(rdpContext *context, UINT32 x, UINT32 y);

static void rdp_OnChannelConnected(void *context, const ChannelConnectedEventArgs *e);
static void rdp_OnChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *e);

static UINT rdp_disp_DisplayControlCaps(DispClientContext *disp, UINT32 MaxNumMonitors,
                                        UINT32 MaxMonitorAreaFactorA, UINT32 MaxMonitorAreaFactorB);
static UINT rdp_cliprdr_ServerCapabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *capabilities);
static UINT rdp_cliprdr_MonitorReady(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *monitorReady);
static UINT rdp_cliprdr_ServerFormatList(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *formatList);
static UINT rdp_cliprdr_ServerFormatDataRequest(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *formatDataRequest);
static UINT rdp_cliprdr_ServerFormatDataResponse(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *formatDataResponse);

@interface RDPConnection ()
{
    NSLock *inputLock;
    NSSize pendingDesktopSize;
}
- (void)threadMain:(id)arg;
- (void)setupCliprdr:(CliprdrClientContext *)cliprdr;
- (NSData *)clipboardData;
- (void)handleServerClipboardData:(NSData *)data;
- (void)performDelayedDesktopSize;
@end

@implementation RDPConnection

- (id)initWithFileHandle:(NSFileHandle *)file server:(id<IServerData>)server
{
    if ((self = [super init]))
    {
        server_ = [server retain];
        socketHandler = [file retain];
        _eventFilter = [[EventFilter alloc] initWithConnection:(id<RemoteConnection>)self];
        frameBuffer = [[RDPFrameBuffer alloc] initWithSize:NSMakeSize(1024, 768)];
        currentDesktopSize = NSMakeSize(1024, 768);
        stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        inputLock = [[NSLock alloc] init];
    }
    return self;
}

- (id)initWithServer:(id<IServerData>)server sshTunnel:(SshTunnel *)tunnel
{
    if ((self = [super init]))
    {
        server_ = [server retain];
        sshTunnel = [tunnel retain];
        _eventFilter = [[EventFilter alloc] initWithConnection:(id<RemoteConnection>)self];
        frameBuffer = [[RDPFrameBuffer alloc] initWithSize:NSMakeSize(1024, 768)];
        currentDesktopSize = NSMakeSize(1024, 768);
        stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        inputLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self closeConnection];
    [server_ release];
    [socketHandler release];
    [_eventFilter release];
    [frameBuffer release];
    [sshTunnel release];
    [password release];
    [username release];

    if (stopEvent)
    {
        CloseHandle(stopEvent);
        stopEvent = NULL;
    }
    [inputLock release];
    inputLock = nil;
    [super dealloc];
}

#pragma mark - FreeRDP Initialization & Thread

- (void)startFreeRDP
{
    RDP_CLIENT_ENTRY_POINTS entryPoints;
    ZeroMemory(&entryPoints, sizeof(entryPoints));
    entryPoints.Size = sizeof(entryPoints);
    entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
    entryPoints.GlobalInit = rdp_client_global_init;
    entryPoints.GlobalUninit = rdp_client_global_uninit;
    entryPoints.ContextSize = sizeof(rdpChickenContext);
    entryPoints.ClientNew = rdp_client_new;
    entryPoints.ClientFree = rdp_client_free;
    entryPoints.ClientStart = rdp_client_start;
    entryPoints.ClientStop = rdp_client_stop;

    rdpContext *ctx = freerdp_client_context_new(&entryPoints);
    if (!ctx)
    {
        NSLog(@"[RDPConnection] Failed to create FreeRDP client context");
        [self notifyDisconnected:@"Failed to initialize FreeRDP"];
        return;
    }

    rdpChickenContext *chickenCtx = (rdpChickenContext *)ctx;
    chickenCtx->connection = (__bridge void *)self;

    freerdpInstance = ctx->instance;
    freerdpContext = ctx;

    freerdp *inst = ctx->instance;
    inst->PreConnect = rdp_PreConnect;
    inst->PostConnect = rdp_PostConnect;
    inst->PostDisconnect = rdp_PostDisconnect;
    inst->VerifyCertificateEx = rdp_VerifyCertificateEx;
    inst->AuthenticateEx = rdp_AuthenticateEx;

    PubSub_SubscribeChannelConnected(ctx->pubSub, (pChannelConnectedEventHandler)rdp_OnChannelConnected);
    PubSub_SubscribeChannelDisconnected(ctx->pubSub, (pChannelDisconnectedEventHandler)rdp_OnChannelDisconnected);

    rdpSettings *settings = ctx->settings;

    NSString *targetHost = [server_ host];
    in_port_t targetPort = [server_ port];
    if (sshTunnel != nil)
    {
        targetHost = @"127.0.0.1";
        targetPort = [sshTunnel localPort];
    }

    freerdp_settings_set_string(settings, FreeRDP_ServerHostname, [targetHost UTF8String]);
    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, targetPort > 0 ? targetPort : 3389);

    freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH);
    freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH);
    freerdp_settings_set_string(settings, FreeRDP_AuthenticationPackageList, "!kerberos,!u2u");

    NSString *userStr = username ? username : [server_ username];
    if (userStr && [userStr length] > 0)
    {
        NSString *domain = nil;
        NSString *cleanUser = nil;
        [server_ getParsedDomain:&domain username:&cleanUser];
        if (domain && [domain length] > 0)
            freerdp_settings_set_string(settings, FreeRDP_Domain, [domain UTF8String]);
        if (cleanUser && [cleanUser length] > 0)
            freerdp_settings_set_string(settings, FreeRDP_Username, [cleanUser UTF8String]);
    }

    NSString *pwdStr = password ? password : [server_ password];
    if (pwdStr && [pwdStr length] > 0)
    {
        freerdp_settings_set_string(settings, FreeRDP_Password, [pwdStr UTF8String]);
        freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, TRUE);
    }

    NSRect viewRect = rfbView ? [rfbView bounds] : NSMakeRect(0, 0, 1024, 768);
    UINT32 initWidth = ((UINT32)viewRect.size.width) & ~1;
    UINT32 initHeight = (UINT32)viewRect.size.height;
    if (initWidth < 640) initWidth = 1024;
    if (initHeight < 480) initHeight = 768;

    freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, initWidth);
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, initHeight);
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_BitmapCacheEnabled, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_FrameMarkerCommandEnabled, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SurfaceFrameMarkerEnabled, TRUE);

    // Channels supported via static linking
    freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxPlanar, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxSmallCache, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxProgressiveV2, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);

    // Audio & Device Redirection (rdpsnd & rdpdr)
    int audioMode = [server_ respondsToSelector:@selector(rdpAudioMode)] ? [server_ rdpAudioMode] : 0;
    BOOL enableAudio = (audioMode == 0);
    BOOL remoteConsoleAudio = (audioMode == 1);

    freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, enableAudio);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, remoteConsoleAudio);
    freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, enableAudio);

    // Keep unused hardware/filesystem device redirections disabled
    freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectHomeDrive, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectSerialPorts, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectParallelPorts, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE);

    // Security negotiation
    freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, TRUE);

    shouldStop = NO;
    workerThread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain:) object:nil];
    [workerThread start];
}

- (void)threadMain:(id)arg
{
    @autoreleasepool {
        freerdp *inst = (freerdp *)freerdpInstance;
        rdpContext *ctx = (rdpContext *)freerdpContext;

        NSLog(@"[RDPConnection] Worker thread: starting freerdp_connect to %@:%u...",
              [server_ host], [server_ port] > 0 ? [server_ port] : 3389);
        BOOL ok = freerdp_connect(inst);
        NSLog(@"[RDPConnection] freerdp_connect returned: %s", ok ? "TRUE" : "FALSE");
        if (!ok)
        {
            UINT32 err = freerdp_get_last_error(ctx);
            const char *errStr = freerdp_get_last_error_string(err);
            const char *errName = freerdp_get_last_error_name(err);
            NSLog(@"[RDPConnection] Connect failed: error 0x%08X [%s] (%s)",
                  err, errName ? errName : "unknown", errStr ? errStr : "unknown");
            NSString *reason = errStr ? [NSString stringWithFormat:@"%s (0x%08X)", errStr, err] : @"RDP connection failed";
            [self performSelectorOnMainThread:@selector(notifyDisconnected:) withObject:reason waitUntilDone:NO];
            return;
        }

        isConnected = YES;

        HANDLE handles[64];
        while (!shouldStop && !freerdp_shall_disconnect_context(ctx))
        {
            DWORD count = freerdp_get_event_handles(ctx, handles, 60);
            if (count == 0)
                break;
            handles[count++] = stopEvent;

            DWORD waitRes = WaitForMultipleObjects(count, handles, FALSE, 100);
            if (waitRes == WAIT_FAILED)
                break;

            if (shouldStop)
                break;

            [inputLock lock];
            BOOL checkOk = freerdp_check_event_handles(ctx);
            [inputLock unlock];

            if (!checkOk)
            {
                UINT32 err = freerdp_get_last_error(ctx);
                NSLog(@"[RDPConnection] freerdp_check_event_handles failed (last error 0x%08X: %s), exiting loop",
                      err, freerdp_get_last_error_string(err));
                break;
            }
        }

        NSLog(@"[RDPConnection] Worker thread: loop exited, disconnecting...");
        freerdp_disconnect(inst);
        isConnected = NO;
        [self performSelectorOnMainThread:@selector(notifyDisconnected:) withObject:nil waitUntilDone:NO];
    }
}

#pragma mark - Callbacks & Handlers

- (void)notifyDirtyRect:(NSRect)rect
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->rfbView)
        {
            NSRect bounds = [self->rfbView bounds];
            NSRect viewRect = rect;
            viewRect.origin.y = bounds.size.height - NSMaxY(rect);
            [self->rfbView setNeedsDisplayInRect:viewRect];
        }
    });
}

- (void)notifyDesktopResize:(NSSize)newSize
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->currentDesktopSize = newSize;
        [self->frameBuffer setSize:newSize];
        rdpContext *ctx = (rdpContext *)self->freerdpContext;
        if (ctx && ctx->gdi)
        {
            [self->frameBuffer setBuffer:ctx->gdi->primary_buffer stride:ctx->gdi->stride];
        }
        if (self->session)
        {
            [self->session resize:newSize];
        }
        if (self->rfbView)
        {
            [self->rfbView setNeedsDisplay:YES];
        }
    });
}

- (void)notifyConnected
{
    NSLog(@"[RDPConnection] notifyConnected called (dispatching to main queue)");
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[RDPConnection] notifyConnected executing on main queue");
        rdpContext *ctx = (rdpContext *)self->freerdpContext;
        if (ctx && ctx->gdi)
        {
            self->currentDesktopSize = NSMakeSize(ctx->gdi->width, ctx->gdi->height);
            NSLog(@"[RDPConnection] Desktop size: %.0fx%.0f, stride=%u, buffer=%p",
                  self->currentDesktopSize.width, self->currentDesktopSize.height,
                  ctx->gdi->stride, ctx->gdi->primary_buffer);
            [self->frameBuffer setSize:self->currentDesktopSize];
            [self->frameBuffer setBuffer:ctx->gdi->primary_buffer stride:ctx->gdi->stride];
        }
        if (self->rfbView)
        {
            [self->rfbView setFrameBuffer:self->frameBuffer];
            [self->rfbView setDelegate:(id<RemoteConnection>)self];
            [self->rfbView setServerCursorTo:[NSCursor arrowCursor]];
        }
        if (self->session)
        {
            [self->session setSize:self->currentDesktopSize];
            NSString *name = [self->server_ name];
            if (!name || [name length] == 0) name = [self->server_ host];
            [self->session setDisplayName:name];
            [self->session setupWindow];
        }
        if (self->rfbView)
        {
            [self->rfbView setNeedsDisplay:YES];
        }
    });
}

- (void)notifyDisconnected:(NSString *)reason
{
    NSLog(@"[RDPConnection] notifyDisconnected: %@", reason);
    if (session)
    {
        [session terminateConnection:reason ? reason : @"Connection closed"];
    }
}

- (void)notifyServerCursor:(NSCursor *)cursor
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->rfbView)
        {
            [self->rfbView setServerCursorTo:cursor];
        }
    });
}

- (BOOL)handleAuthenticateUser:(char **)outUser password:(char **)outPwd domain:(char **)outDom reason:(rdp_auth_reason)reason
{
    NSString *userStr = username ? username : [server_ username];
    NSString *pwdStr = password ? password : [server_ password];
    NSString *domainStr = nil;
    NSString *cleanUser = nil;
    if (userStr && [userStr length] > 0)
    {
        [server_ getParsedDomain:&domainStr username:&cleanUser];
    }

    if (outUser && cleanUser && [cleanUser length] > 0)
    {
        if (*outUser) free(*outUser);
        *outUser = strdup([cleanUser UTF8String]);
    }
    if (outDom && domainStr && [domainStr length] > 0)
    {
        if (*outDom) free(*outDom);
        *outDom = strdup([domainStr UTF8String]);
    }
    if (outPwd && pwdStr && [pwdStr length] > 0)
    {
        if (*outPwd) free(*outPwd);
        *outPwd = strdup([pwdStr UTF8String]);
    }
    NSLog(@"[RDPConnection] AuthenticateEx handled: user=%s domain=%s pwd=%s",
          (outUser && *outUser) ? *outUser : "(null)",
          (outDom && *outDom) ? *outDom : "(null)",
          (outPwd && *outPwd) ? "***" : "(null)");
    return TRUE;
}

- (void)handleChannelConnected:(const char *)name pInterface:(void *)pInterface
{
    if (strcmp(name, DISP_DVC_CHANNEL_NAME) == 0)
    {
        dispContext = pInterface;
        DispClientContext *disp = (DispClientContext *)pInterface;
        rdpChickenContext *c = (rdpChickenContext *)freerdpContext;
        disp->custom = c;
        disp->DisplayControlCaps = rdp_disp_DisplayControlCaps;
    }
    else if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
    {
        cliprdrContext = pInterface;
        [self setupCliprdr:(CliprdrClientContext *)pInterface];
    }
}

- (void)handleChannelDisconnected:(const char *)name
{
    if (strcmp(name, DISP_DVC_CHANNEL_NAME) == 0)
    {
        dispContext = NULL;
        dispReady = NO;
    }
    else if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
    {
        cliprdrContext = NULL;
        cliprdrReady = NO;
    }
}

#pragma mark - Clipboard

- (void)setupCliprdr:(CliprdrClientContext *)cliprdr
{
    rdpChickenContext *c = (rdpChickenContext *)freerdpContext;
    cliprdr->custom = c;
    cliprdr->ServerCapabilities = rdp_cliprdr_ServerCapabilities;
    cliprdr->MonitorReady = rdp_cliprdr_MonitorReady;
    cliprdr->ServerFormatList = rdp_cliprdr_ServerFormatList;
    cliprdr->ServerFormatDataRequest = rdp_cliprdr_ServerFormatDataRequest;
    cliprdr->ServerFormatDataResponse = rdp_cliprdr_ServerFormatDataResponse;
}

- (NSData *)clipboardData
{
    __block NSData *data = nil;
    if ([NSThread isMainThread])
    {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if (str)
            data = [[str dataUsingEncoding:NSUTF16LittleEndianStringEncoding] retain];
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            NSString *str = [pb stringForType:NSPasteboardTypeString];
            if (str)
                data = [[str dataUsingEncoding:NSUTF16LittleEndianStringEncoding] retain];
        });
    }
    return [data autorelease];
}

- (void)handleServerClipboardData:(NSData *)data
{
    if (!data || [data length] == 0)
        return;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    if (text)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
            [text release];
        });
    }
}

#pragma mark - RemoteConnection Protocol

- (id<IServerData>)server { return server_; }
- (SshTunnel *)sshTunnel { return sshTunnel; }
- (NSString *)password { return password; }
- (NSString *)username { return username; }
- (Profile *)profile
{
    Profile *p = [server_ profile];
    if (p) return p;
    Profile *winProf = [[ProfileDataManager sharedInstance] profileForKey:@"Windows"];
    if (winProf) return winProf;
    return [[ProfileDataManager sharedInstance] defaultProfile];
}
- (EventFilter *)eventFilter { return _eventFilter; }
- (BOOL)viewOnly { return [server_ viewOnly]; }

- (Session *)session
{
    return session;
}

- (void)setSession:(Session *)aSession
{
    session = aSession;
    if (rfbView && !workerThread)
    {
        [self startFreeRDP];
    }
}

- (void)setRfbView:(RFBView *)view
{
    rfbView = view;
    [_eventFilter setView:rfbView];
    if (session && !workerThread)
    {
        [self startFreeRDP];
    }
}

- (void)setUsername:(NSString *)aUsername
{
    [username autorelease];
    username = [aUsername copy];
}

- (void)setPassword:(NSString *)aPassword
{
    [password autorelease];
    password = [aPassword copy];
}

- (void)setSshTunnel:(SshTunnel *)tunnel
{
    [sshTunnel autorelease];
    sshTunnel = [tunnel retain];
}

- (void)closeConnection
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performDelayedDesktopSize) object:nil];

    shouldStop = YES;
    dispReady = NO;
    cliprdrReady = NO;
    if (stopEvent)
        SetEvent(stopEvent);

    if (freerdpContext && !isConnected && workerThread)
    {
        freerdp_abort_connect_context((rdpContext *)freerdpContext);
    }

    if (frameBuffer)
    {
        [frameBuffer setBuffer:NULL stride:0];
    }

    if (rfbView)
    {
        [rfbView setDelegate:nil];
        [rfbView setFrameBuffer:nil];
        rfbView = nil;
    }
    session = nil;

    if (workerThread)
    {
        while ([workerThread isExecuting])
            [NSThread sleepForTimeInterval:0.01];
        [workerThread release];
        workerThread = nil;
    }

    if (freerdpContext)
    {
        freerdp_client_context_free((rdpContext *)freerdpContext);
        freerdpContext = NULL;
        freerdpInstance = NULL;
    }
}

- (void)terminateConnection:(NSString *)aReason
{
    [self closeConnection];
    if (session)
        [session terminateConnection:aReason];
}

- (BOOL)serverSupportsSetDesktopSize
{
    return (dispContext != NULL && dispReady);
}

- (void)writeSetDesktopSize:(NSSize)newSize
{
    UINT32 w = ((UINT32)newSize.width) & ~1;
    UINT32 h = (UINT32)newSize.height;
    if (w < 200 || h < 200)
        return;

    if (w == (UINT32)currentDesktopSize.width && h == (UINT32)currentDesktopSize.height)
        return;

    pendingDesktopSize = NSMakeSize(w, h);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performDelayedDesktopSize) object:nil];
    [self performSelector:@selector(performDelayedDesktopSize) withObject:nil afterDelay:0.25];
}

- (void)performDelayedDesktopSize
{
    if (dispContext != NULL && dispReady && isConnected)
    {
        NSSize newSize = pendingDesktopSize;
        if (newSize.width < 200 || newSize.height < 200)
            return;

        UINT32 w = ((UINT32)newSize.width) & ~1; // Must be even per MS-RDPEDISP § 2.2.2.2.1
        UINT32 h = (UINT32)newSize.height;
        if (w < 200) w = 200;
        if (w > 8192) w = 8192;
        if (h < 200) h = 200;
        if (h > 8192) h = 8192;

        if (w == (UINT32)currentDesktopSize.width && h == (UINT32)currentDesktopSize.height)
            return;

        NSLog(@"[RDPConnection] Sending DisplayControl monitor layout: %ux%u", w, h);

        DISPLAY_CONTROL_MONITOR_LAYOUT layout;
        ZeroMemory(&layout, sizeof(layout));
        layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        layout.Left = 0;
        layout.Top = 0;
        layout.Width = w;
        layout.Height = h;
        layout.Orientation = ORIENTATION_LANDSCAPE;
        layout.PhysicalWidth = (UINT32)(w * 25.4 / 96.0);
        layout.PhysicalHeight = (UINT32)(h * 25.4 / 96.0);
        if (layout.PhysicalWidth < 10) layout.PhysicalWidth = 10;
        if (layout.PhysicalHeight < 10) layout.PhysicalHeight = 10;

        [inputLock lock];
        DispClientContext *disp = (DispClientContext *)dispContext;
        if (disp && disp->SendMonitorLayout)
        {
            disp->SendMonitorLayout(disp, 1, &layout);
        }
        [inputLock unlock];
    }
}

- (NSString *)statisticsString
{
    return isConnected ? @"Connected" : @"Connecting...";
}

- (NSString *)infoString
{
    return [NSString stringWithFormat:@"RDP 3.x (%d x %d, 32 bpp)",
            (int)currentDesktopSize.width, (int)currentDesktopSize.height];
}

- (void)requestFrameBufferUpdate:(id)sender {}
- (void)forceFrameBufferUpdate {}
- (void)setFrameBufferUpdateSeconds:(float)seconds {}
- (void)installMouseMovedTrackingRect {}
- (void)removeMouseMovedTrackingRect {}
- (void)viewFrameDidChange:(NSNotification *)notification {}

- (BOOL)pasteFromPasteboard:(NSPasteboard *)pasteboard
{
    [self sendPasteboardToServer:pasteboard];
    return YES;
}

- (void)sendPasteboardToServer:(NSPasteboard *)pasteboard
{
    [inputLock lock];
    if (!cliprdrContext || !cliprdrReady || !isConnected)
    {
        [inputLock unlock];
        return;
    }

    CliprdrClientContext *cliprdr = (CliprdrClientContext *)cliprdrContext;
    CLIPRDR_FORMAT format;
    ZeroMemory(&format, sizeof(format));
    format.formatId = 13; // CF_UNICODETEXT

    CLIPRDR_FORMAT_LIST formatList;
    ZeroMemory(&formatList, sizeof(formatList));
    formatList.common.msgFlags = 0;
    formatList.numFormats = 1;
    formatList.formats = &format;
    cliprdr->ClientFormatList(cliprdr, &formatList);
    [inputLock unlock];
}

- (void)sendKeyCode:(unsigned int)key pressed:(BOOL)pressed
{
    if (!freerdpContext || !isConnected)
        return;

    DWORD vk = 0;
    BOOL extended = NO;
    switch (key)
    {
        case XK_Control_L: vk = VK_LCONTROL; break;
        case XK_Control_R: vk = VK_RCONTROL; extended = YES; break;
        case XK_Alt_L: vk = VK_LMENU; break;
        case XK_Alt_R: vk = VK_RMENU; extended = YES; break;
        case XK_Shift_L: vk = VK_LSHIFT; break;
        case XK_Shift_R: vk = VK_RSHIFT; break;
        case XK_Meta_L:
        case XK_Super_L: vk = VK_LWIN; extended = YES; break;
        case XK_Meta_R:
        case XK_Super_R: vk = VK_RWIN; extended = YES; break;
        case XK_Delete: vk = VK_DELETE; extended = YES; break;
        case XK_Insert: vk = VK_INSERT; extended = YES; break;
        case XK_Pause: vk = VK_PAUSE; break;
        case XK_Escape: vk = VK_ESCAPE; break;
        case XK_Print: vk = VK_SNAPSHOT; break;
        default: vk = (DWORD)key; break;
    }
    DWORD vkLookup = extended ? (vk | KBDEXT) : vk;
    DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkLookup, 4);

    [inputLock lock];
    if (freerdpContext && isConnected)
    {
        rdpContext *ctx = (rdpContext *)freerdpContext;
        if (ctx && ctx->input)
        {
            freerdp_input_send_keyboard_event_ex(ctx->input, pressed, NO, (UINT32)scancode);
        }
    }
    [inputLock unlock];
}

- (void)writeBuffer {}
- (FrameBuffer *)frameBuffer { return frameBuffer; }

#pragma mark - Mouse & Key Events from EventFilter

- (void)mouseAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    if (!freerdpContext || !isConnected)
        return;

    UINT16 x = (UINT16)thePoint.x;
    UINT16 y = (UINT16)([rfbView bounds].size.height - thePoint.y);

    [inputLock lock];
    if (freerdpContext && isConnected)
    {
        rdpContext *ctx = (rdpContext *)freerdpContext;
        if (ctx && ctx->input)
        {
            freerdp_input_send_mouse_event(ctx->input, PTR_FLAGS_MOVE, x, y);
        }
    }
    [inputLock unlock];
}

- (void)mouseClickedAt:(NSPoint)thePoint buttons:(unsigned int)mask
{
    if (!freerdpContext || !isConnected)
        return;

    UINT16 x = (UINT16)thePoint.x;
    UINT16 y = (UINT16)([rfbView bounds].size.height - thePoint.y);

    unsigned int changed = mask ^ _pressedButtons;

    [inputLock lock];
    if (freerdpContext && isConnected)
    {
        rdpContext *ctx = (rdpContext *)freerdpContext;
        if (ctx && ctx->input)
        {
            if (changed & 1 /* left */)
            {
                UINT16 flags = PTR_FLAGS_BUTTON1 | ((mask & 1) ? PTR_FLAGS_DOWN : 0);
                freerdp_input_send_mouse_event(ctx->input, flags, x, y);
            }
            if (changed & 4 /* right */)
            {
                UINT16 flags = PTR_FLAGS_BUTTON2 | ((mask & 4) ? PTR_FLAGS_DOWN : 0);
                freerdp_input_send_mouse_event(ctx->input, flags, x, y);
            }
            if (changed & 2 /* middle */)
            {
                UINT16 flags = PTR_FLAGS_BUTTON3 | ((mask & 2) ? PTR_FLAGS_DOWN : 0);
                freerdp_input_send_mouse_event(ctx->input, flags, x, y);
            }
            if (mask & 8 /* wheel up */)
            {
                freerdp_input_send_mouse_event(ctx->input, PTR_FLAGS_WHEEL | 0x0078, x, y);
            }
            if (mask & 16 /* wheel down */)
            {
                freerdp_input_send_mouse_event(ctx->input, PTR_FLAGS_WHEEL | PTR_FLAGS_WHEEL_NEGATIVE | 0x0078, x, y);
            }
        }
    }
    [inputLock unlock];

    _pressedButtons = mask;
}

- (void)sendKey:(unichar)c pressed:(BOOL)pressed
{
    if (!freerdpContext || !isConnected)
        return;

    DWORD vk = 0;
    BOOL extended = NO;

    switch (c)
    {
        case NSUpArrowFunctionKey: vk = VK_UP; extended = YES; break;
        case NSDownArrowFunctionKey: vk = VK_DOWN; extended = YES; break;
        case NSLeftArrowFunctionKey: vk = VK_LEFT; extended = YES; break;
        case NSRightArrowFunctionKey: vk = VK_RIGHT; extended = YES; break;
        case NSF1FunctionKey: vk = VK_F1; break;
        case NSF2FunctionKey: vk = VK_F2; break;
        case NSF3FunctionKey: vk = VK_F3; break;
        case NSF4FunctionKey: vk = VK_F4; break;
        case NSF5FunctionKey: vk = VK_F5; break;
        case NSF6FunctionKey: vk = VK_F6; break;
        case NSF7FunctionKey: vk = VK_F7; break;
        case NSF8FunctionKey: vk = VK_F8; break;
        case NSF9FunctionKey: vk = VK_F9; break;
        case NSF10FunctionKey: vk = VK_F10; break;
        case NSF11FunctionKey: vk = VK_F11; break;
        case NSF12FunctionKey: vk = VK_F12; break;
        case NSInsertFunctionKey: vk = VK_INSERT; extended = YES; break;
        case NSDeleteFunctionKey: vk = VK_DELETE; extended = YES; break;
        case NSHomeFunctionKey: vk = VK_HOME; extended = YES; break;
        case NSEndFunctionKey: vk = VK_END; extended = YES; break;
        case NSPageUpFunctionKey: vk = VK_PRIOR; extended = YES; break;
        case NSPageDownFunctionKey: vk = VK_NEXT; extended = YES; break;
        case 0x7F:
        case 0x08: vk = VK_BACK; break;
        case 0x09: vk = VK_TAB; break;
        case 0x0D:
        case 0x03: vk = VK_RETURN; break;
        case 0x1B: vk = VK_ESCAPE; break;
        case ' ':  vk = VK_SPACE; break;

        // Numeric keypad keys (offset by 0xf600 in EventFilter)
        case 0xf603: vk = VK_RETURN; extended = YES; break; // Keypad Enter
        case 0xf62a: vk = VK_MULTIPLY; break;               // Keypad *
        case 0xf62b: vk = VK_ADD; break;                    // Keypad +
        case 0xf62d: vk = VK_SUBTRACT; break;               // Keypad -
        case 0xf62e: vk = VK_DECIMAL; break;                // Keypad .
        case 0xf62f: vk = VK_DIVIDE; extended = YES; break; // Keypad /
        case 0xf63d: vk = VK_OEM_PLUS; break;               // Keypad =
        case 0xf61b:
        case 0xf619: vk = VK_CLEAR; break;                  // Keypad Clear

        // Punctuation & symbols
        case ';':
        case ':': vk = VK_OEM_1; break;
        case '=':
        case '+': vk = VK_OEM_PLUS; break;
        case ',':
        case '<': vk = VK_OEM_COMMA; break;
        case '-':
        case '_': vk = VK_OEM_MINUS; break;
        case '.':
        case '>': vk = VK_OEM_PERIOD; break;
        case '/':
        case '?': vk = VK_OEM_2; break;
        case '`':
        case '~': vk = VK_OEM_3; break;
        case '[':
        case '{': vk = VK_OEM_4; break;
        case '\\':
        case '|': vk = VK_OEM_5; break;
        case ']':
        case '}': vk = VK_OEM_6; break;
        case '\'':
        case '"': vk = VK_OEM_7; break;

        default:
            if (c >= 'a' && c <= 'z')
                vk = VK_KEY_A + (c - 'a');
            else if (c >= 'A' && c <= 'Z')
                vk = VK_KEY_A + (c - 'A');
            else if (c >= '0' && c <= '9')
                vk = VK_KEY_0 + (c - '0');
            else if (c >= 0xf630 && c <= 0xf639)
                vk = VK_NUMPAD0 + (c - 0xf630);
            break;
    }

    [inputLock lock];
    if (freerdpContext && isConnected)
    {
        rdpContext *ctx = (rdpContext *)freerdpContext;
        if (ctx && ctx->input)
        {
            if (vk != 0)
            {
                DWORD vkLookup = extended ? (vk | KBDEXT) : vk;
                DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkLookup, 4);
                freerdp_input_send_keyboard_event_ex(ctx->input, pressed, NO, (UINT32)scancode);
            }
            else
            {
                UINT16 flags = pressed ? 0 : KBD_FLAGS_RELEASE;
                freerdp_input_send_unicode_keyboard_event(ctx->input, flags, (UINT16)c);
            }
        }
    }
    [inputLock unlock];
}

- (void)sendModifier:(unsigned int)m pressed:(BOOL)pressed
{
    if (!freerdpContext || !isConnected)
        return;

    Profile *prof = [self profile];
    CARD32 keysym = XK_VoidSymbol;
    if (NSEventModifierFlagShift == m)
        keysym = prof ? [prof shiftKeyCode] : XK_Shift_L;
    else if (NSEventModifierFlagControl == m)
        keysym = prof ? [prof controlKeyCode] : XK_Control_L;
    else if (NSEventModifierFlagOption == m)
        keysym = prof ? [prof altKeyCode] : XK_Alt_L;
    else if (NSEventModifierFlagCommand == m)
        keysym = prof ? [prof commandKeyCode] : XK_Super_L;
    else if (NSEventModifierFlagCapsLock == m)
        keysym = XK_Caps_Lock;
    else
        return;

    if (keysym == XK_VoidSymbol)
        return;

    DWORD vk = 0;
    BOOL extended = NO;
    switch (keysym)
    {
        case XK_Control_L: vk = VK_LCONTROL; break;
        case XK_Control_R: vk = VK_RCONTROL; extended = YES; break;
        case XK_Alt_L: vk = VK_LMENU; break;
        case XK_Alt_R: vk = VK_RMENU; extended = YES; break;
        case XK_Shift_L: vk = VK_LSHIFT; break;
        case XK_Shift_R: vk = VK_RSHIFT; break;
        case XK_Meta_L:
        case XK_Super_L: vk = VK_LWIN; extended = YES; break;
        case XK_Meta_R:
        case XK_Super_R: vk = VK_RWIN; extended = YES; break;
        case XK_Caps_Lock: vk = VK_CAPITAL; break;
        default: break;
    }

    if (vk != 0)
    {
        DWORD vkLookup = extended ? (vk | KBDEXT) : vk;
        DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkLookup, 4);

        [inputLock lock];
        if (freerdpContext && isConnected)
        {
            rdpContext *ctx = (rdpContext *)freerdpContext;
            if (ctx && ctx->input)
            {
                freerdp_input_send_keyboard_event_ex(ctx->input, pressed, NO, (UINT32)scancode);
            }
        }
        [inputLock unlock];
    }
}

@end

#pragma mark - FreeRDP C Callbacks Implementation

static BOOL rdp_BeginPaint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd && gdi->primary->hdc->hwnd->invalid)
    {
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    }
    return TRUE;
}

static BOOL rdp_EndPaint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;

    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (!hwnd->invalid || hwnd->invalid->null)
        return TRUE;

    int x = hwnd->invalid->x;
    int y = hwnd->invalid->y;
    int w = hwnd->invalid->w;
    int h = hwnd->invalid->h;

    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;

    if (w > 0 && h > 0)
    {
        rdpChickenContext *c = (rdpChickenContext *)context;
        RDPConnection *conn = (__bridge RDPConnection *)c->connection;
        [conn notifyDirtyRect:NSMakeRect(x, y, w, h)];
    }
    return TRUE;
}

static BOOL rdp_PreConnect(freerdp *instance)
{
    NSLog(@"[RDPConnection] PreConnect callback invoked");
    instance->context->update->BeginPaint = rdp_BeginPaint;
    instance->context->update->EndPaint = rdp_EndPaint;
    instance->context->update->DesktopResize = rdp_DesktopResize;

    return TRUE;
}

static BOOL rdp_PostConnect(freerdp *instance)
{
    NSLog(@"[RDPConnection] PostConnect callback invoked! Initializing GDI...");
    rdpChickenContext *c = (rdpChickenContext *)instance->context;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;

    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
    {
        NSLog(@"[RDPConnection] gdi_init failed!");
        return FALSE;
    }

    NSLog(@"[RDPConnection] gdi_init succeeded: %ux%u", instance->context->gdi->width, instance->context->gdi->height);

    rdpPointer rdp_pointer;
    ZeroMemory(&rdp_pointer, sizeof(rdp_pointer));
    rdp_pointer.size = sizeof(rdpChickenPointer);
    rdp_pointer.New = rdp_Pointer_New;
    rdp_pointer.Free = rdp_Pointer_Free;
    rdp_pointer.Set = rdp_Pointer_Set;
    rdp_pointer.SetNull = rdp_Pointer_SetNull;
    rdp_pointer.SetDefault = rdp_Pointer_SetDefault;
    rdp_pointer.SetPosition = rdp_Pointer_SetPosition;

    graphics_register_pointer(instance->context->graphics, &rdp_pointer);

    [conn notifyConnected];
    return TRUE;
}

static BOOL rdp_Pointer_New(rdpContext *context, rdpPointer *pointer)
{
    rdpChickenPointer *cPtr = (rdpChickenPointer *)pointer;
    if (!pointer || pointer->width == 0 || pointer->height == 0)
        return TRUE;

    size_t dataSize = (size_t)pointer->width * pointer->height * 4;
    BYTE *cursor_data = (BYTE *)malloc(dataSize);
    if (!cursor_data)
        return FALSE;

    UINT32 format = PIXEL_FORMAT_RGBA32;
    if (!freerdp_image_copy_from_pointer_data(cursor_data, format, 0, 0, 0, pointer->width,
                                              pointer->height, pointer->xorMaskData,
                                              pointer->lengthXorMask, pointer->andMaskData,
                                              pointer->lengthAndMask, pointer->xorBpp, NULL))
    {
        free(cursor_data);
        return FALSE;
    }

    NSBitmapImageRep *bmiRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pointer->width
                      pixelsHigh:pointer->height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:pointer->width * 4
                    bitsPerPixel:32];

    if (bmiRep)
    {
        memcpy([bmiRep bitmapData], cursor_data, dataSize);
        free(cursor_data);

        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(pointer->width, pointer->height)];
        [image addRepresentation:bmiRep];
        [bmiRep release];

        NSPoint hotSpot = NSMakePoint(pointer->xPos, pointer->yPos);
        cPtr->cursor = [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
        [image release];
    }
    else
    {
        free(cursor_data);
    }

    return TRUE;
}

static void rdp_Pointer_Free(rdpContext *context, rdpPointer *pointer)
{
    rdpChickenPointer *cPtr = (rdpChickenPointer *)pointer;
    if (cPtr && cPtr->cursor)
    {
        [cPtr->cursor release];
        cPtr->cursor = nil;
    }
}

static BOOL rdp_Pointer_Set(rdpContext *context, rdpPointer *pointer)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    if (!c || !c->connection) return TRUE;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    rdpChickenPointer *cPtr = (rdpChickenPointer *)pointer;
    if (!cPtr || !cPtr->cursor) return TRUE;
    [conn notifyServerCursor:cPtr->cursor];
    return TRUE;
}

static BOOL rdp_Pointer_SetDefault(rdpContext *context)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    if (!c || !c->connection) return TRUE;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    [conn notifyServerCursor:[NSCursor arrowCursor]];
    return TRUE;
}

static BOOL rdp_Pointer_SetNull(rdpContext *context)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    if (!c || !c->connection) return TRUE;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    [conn notifyServerCursor:nil];
    return TRUE;
}

static BOOL rdp_Pointer_SetPosition(rdpContext *context, UINT32 x, UINT32 y)
{
    return TRUE;
}

static void rdp_PostDisconnect(freerdp *instance)
{
    gdi_free(instance);
}

static BOOL rdp_DesktopResize(rdpContext *context)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    rdpSettings *settings = context->settings;
    UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

    NSLog(@"[RDPConnection] DesktopResize callback: resizing GDI to %ux%u", width, height);

    if (context->gdi)
    {
        if (!gdi_resize(context->gdi, width, height))
        {
            NSLog(@"[RDPConnection] gdi_resize failed for %ux%u!", width, height);
            return FALSE;
        }

        RDPConnection *conn = (__bridge RDPConnection *)c->connection;
        [conn notifyDesktopResize:NSMakeSize(width, height)];
    }
    return TRUE;
}

static DWORD rdp_VerifyCertificateEx(freerdp *instance, const char *host, UINT16 port,
                                     const char *common_name, const char *subject,
                                     const char *issuer, const char *fingerprint, DWORD flags)
{
    NSLog(@"[RDPConnection] VerifyCertificateEx: host=%s port=%u fp=%s", host, port, fingerprint);
    return 1;
}

static BOOL rdp_AuthenticateEx(freerdp *instance, char **username, char **password,
                               char **domain, rdp_auth_reason reason)
{
    NSLog(@"[RDPConnection] AuthenticateEx callback (reason=%u)", reason);
    rdpChickenContext *c = (rdpChickenContext *)instance->context;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    return [conn handleAuthenticateUser:username password:password domain:domain reason:reason];
}

static void rdp_OnChannelConnected(void *context, const ChannelConnectedEventArgs *e)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    [conn handleChannelConnected:e->name pInterface:e->pInterface];
    freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void rdp_OnChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    rdpChickenContext *c = (rdpChickenContext *)context;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;
    [conn handleChannelDisconnected:e->name];
    freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

static UINT rdp_disp_DisplayControlCaps(DispClientContext *disp, UINT32 MaxNumMonitors,
                                        UINT32 MaxMonitorAreaFactorA, UINT32 MaxMonitorAreaFactorB)
{
    NSLog(@"[RDPConnection] DisplayControlCaps received: maxMonitors=%u", MaxNumMonitors);
    rdpChickenContext *c = (rdpChickenContext *)disp->custom;
    if (c && c->connection)
    {
        RDPConnection *conn = (__bridge RDPConnection *)c->connection;
        conn->dispReady = YES;
    }
    return CHANNEL_RC_OK;
}

static UINT rdp_cliprdr_ServerCapabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *capabilities)
{
    return CHANNEL_RC_OK;
}

static UINT rdp_cliprdr_MonitorReady(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *monitorReady)
{
    NSLog(@"[RDPConnection] cliprdr MonitorReady received from server");
    rdpChickenContext *c = (rdpChickenContext *)cliprdr->custom;
    if (c && c->connection)
    {
        RDPConnection *conn = (__bridge RDPConnection *)c->connection;
        conn->cliprdrReady = YES;
    }

    CLIPRDR_GENERAL_CAPABILITY_SET generalCaps;
    CLIPRDR_CAPABILITIES caps;
    ZeroMemory(&generalCaps, sizeof(generalCaps));
    generalCaps.capabilitySetType = CB_CAPSTYPE_GENERAL;
    generalCaps.capabilitySetLength = 12;
    generalCaps.version = CB_CAPS_VERSION_2;
    generalCaps.generalFlags = CB_USE_LONG_FORMAT_NAMES;

    ZeroMemory(&caps, sizeof(caps));
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&generalCaps;
    cliprdr->ClientCapabilities(cliprdr, &caps);

    CLIPRDR_FORMAT format;
    ZeroMemory(&format, sizeof(format));
    format.formatId = 13; // CF_UNICODETEXT

    CLIPRDR_FORMAT_LIST formatList;
    ZeroMemory(&formatList, sizeof(formatList));
    formatList.common.msgFlags = 0;
    formatList.numFormats = 1;
    formatList.formats = &format;
    cliprdr->ClientFormatList(cliprdr, &formatList);

    return CHANNEL_RC_OK;
}

static UINT rdp_cliprdr_ServerFormatList(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *formatList)
{
    BOOL hasUnicode = NO;
    for (UINT32 i = 0; i < formatList->numFormats; i++)
    {
        if (formatList->formats[i].formatId == 13 /* CF_UNICODETEXT */)
        {
            hasUnicode = YES;
            break;
        }
    }

    CLIPRDR_FORMAT_LIST_RESPONSE resp;
    ZeroMemory(&resp, sizeof(resp));
    resp.common.msgFlags = CB_RESPONSE_OK;
    cliprdr->ClientFormatListResponse(cliprdr, &resp);

    if (hasUnicode)
    {
        CLIPRDR_FORMAT_DATA_REQUEST req;
        ZeroMemory(&req, sizeof(req));
        req.requestedFormatId = 13;
        cliprdr->ClientFormatDataRequest(cliprdr, &req);
    }
    return CHANNEL_RC_OK;
}

static UINT rdp_cliprdr_ServerFormatDataRequest(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *formatDataRequest)
{
    rdpChickenContext *c = (rdpChickenContext *)cliprdr->custom;
    if (!c) c = (rdpChickenContext *)cliprdr->rdpcontext;
    if (!c || !c->connection) return CHANNEL_RC_OK;
    RDPConnection *conn = (__bridge RDPConnection *)c->connection;

    CLIPRDR_FORMAT_DATA_RESPONSE resp;
    ZeroMemory(&resp, sizeof(resp));

    if (formatDataRequest->requestedFormatId == 13 /* CF_UNICODETEXT */)
    {
        NSData *data = [conn clipboardData];
        if (data)
        {
            resp.common.msgFlags = CB_RESPONSE_OK;
            resp.common.dataLen = (UINT32)[data length];
            resp.requestedFormatData = (const BYTE *)[data bytes];
            return cliprdr->ClientFormatDataResponse(cliprdr, &resp);
        }
    }

    resp.common.msgFlags = CB_RESPONSE_FAIL;
    return cliprdr->ClientFormatDataResponse(cliprdr, &resp);
}

static UINT rdp_cliprdr_ServerFormatDataResponse(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *formatDataResponse)
{
    if (formatDataResponse->common.msgFlags & CB_RESPONSE_OK && formatDataResponse->common.dataLen > 0)
    {
        rdpChickenContext *c = (rdpChickenContext *)cliprdr->custom;
        if (!c) c = (rdpChickenContext *)cliprdr->rdpcontext;
        if (!c || !c->connection) return CHANNEL_RC_OK;
        RDPConnection *conn = (__bridge RDPConnection *)c->connection;
        NSData *data = [NSData dataWithBytes:formatDataResponse->requestedFormatData length:formatDataResponse->common.dataLen];
        [conn handleServerClipboardData:data];
    }
    return CHANNEL_RC_OK;
}
