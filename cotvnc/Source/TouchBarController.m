//
//  TouchBarController.m
//  Chicken of the VNC
//

#import "TouchBarController.h"
#import "RFBConnectionManager.h"
#import "ServerDataManager.h"
#import "ServerDataViewController.h"
#import "ServerBase.h"
#import "Session.h"

NSString * const cotvncTouchBarNeedsUpdateNotification = @"cotvncTouchBarNeedsUpdateNotification";

static NSTouchBarCustomizationIdentifier cotvncTouchBarCustomization = @"net.sourceforge.chicken.touchbar";
static NSTouchBarItemIdentifier cotvncTouchBarShowConnections = @"net.sourceforge.chicken.touchbar.showConnections";
static NSTouchBarItemIdentifier cotvncTouchBarServerScrubber = @"net.sourceforge.chicken.touchbar.serverScrubber";

@interface TouchBarController ()
{
    NSTouchBar *mCurrentTouchBar;
    NSScrubber *mScrubber;
    NSInteger mLastActionIndex;
    NSTimeInterval mLastActionTime;
}
@end

@implementation TouchBarController

+ (TouchBarController *)sharedController
{
    static TouchBarController *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[TouchBarController alloc] init];
    });
    return sInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        mLastActionIndex = -1;
        mLastActionTime = 0;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(updateTouchBar) name:NSWindowDidBecomeKeyNotification object:nil];
        [nc addObserver:self selector:@selector(updateTouchBar) name:NSWindowWillCloseNotification object:nil];
        [nc addObserver:self selector:@selector(updateTouchBar) name:cotvncTouchBarNeedsUpdateNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [mCurrentTouchBar release];
    [mScrubber release];
    [super dealloc];
}

- (NSTouchBar *)makeTouchBar
{
    NSTouchBar *touchBar = [[[NSTouchBar alloc] init] autorelease];
    touchBar.customizationIdentifier = cotvncTouchBarCustomization;
    touchBar.delegate = self;
    touchBar.defaultItemIdentifiers = @[
        cotvncTouchBarShowConnections,
        cotvncTouchBarServerScrubber
    ];
    touchBar.customizationAllowedItemIdentifiers = touchBar.defaultItemIdentifiers;
    
    [mCurrentTouchBar release];
    mCurrentTouchBar = [touchBar retain];
    
    return touchBar;
}

- (void)updateTouchBar
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->mScrubber) {
            [self->mScrubber reloadData];
        }
        else if (self->mCurrentTouchBar) {
            NSArray *items = self->mCurrentTouchBar.defaultItemIdentifiers;
            self->mCurrentTouchBar.defaultItemIdentifiers = @[];
            self->mCurrentTouchBar.defaultItemIdentifiers = items;
        }
    });
}

- (Session *)activeSessionForServerName:(NSString *)serverName
{
    if (!serverName || [serverName length] == 0) {
        return nil;
    }
    NSArray *sessions = [[RFBConnectionManager sharedManager] sessions];
    for (Session *sess in sessions) {
        if ([sess isConnected]) {
            NSString *pName = [sess serverProfileName];
            if (pName && [pName isEqualToString:serverName]) {
                return sess;
            }
        }
    }
    return nil;
}

#pragma mark - NSTouchBarDelegate

- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    if ([identifier isEqualToString:cotvncTouchBarShowConnections]) {
        NSCustomTouchBarItem *item = [[[NSCustomTouchBarItem alloc] initWithIdentifier:identifier] autorelease];
        item.customizationLabel = @"Connection Window";
        
        NSImage *icon = nil;
        if (@available(macOS 11.0, *)) {
            icon = [NSImage imageWithSystemSymbolName:@"network" accessibilityDescription:@"Connections"];
        }
        if (!icon) {
            icon = [NSImage imageNamed:NSImageNameNetwork];
        }
        
        NSButton *btn = [NSButton buttonWithImage:icon target:self action:@selector(showConnectionWindowPressed:)];
        btn.imagePosition = NSImageOnly;
        item.view = btn;
        return item;
    }
    else if ([identifier isEqualToString:cotvncTouchBarServerScrubber]) {
        NSCustomTouchBarItem *item = [[[NSCustomTouchBarItem alloc] initWithIdentifier:identifier] autorelease];
        item.customizationLabel = @"Server Connections";
        
        NSScrubber *scrubber = [[[NSScrubber alloc] initWithFrame:NSMakeRect(0, 0, 400, 30)] autorelease];
        scrubber.dataSource = self;
        scrubber.delegate = self;
        scrubber.mode = NSScrubberModeFree;
        scrubber.showsAdditionalContentIndicators = YES;
        scrubber.selectionBackgroundStyle = nil;
        scrubber.selectionOverlayStyle = nil;
        
        NSScrubberFlowLayout *layout = [[[NSScrubberFlowLayout alloc] init] autorelease];
        layout.itemSpacing = 6.0;
        scrubber.scrubberLayout = layout;
        
        [scrubber registerClass:[NSScrubberTextItemView class] forItemIdentifier:@"ServerItem"];
        
        [mScrubber release];
        mScrubber = [scrubber retain];
        
        item.view = scrubber;
        return item;
    }
    
    return nil;
}

#pragma mark - NSScrubberDataSource

- (NSInteger)numberOfItemsForScrubber:(NSScrubber *)scrubber
{
    NSArray *serverNames = [[ServerDataManager sharedInstance] sortedServerNames];
    return (NSInteger)[serverNames count];
}

- (NSScrubberItemView *)scrubber:(NSScrubber *)scrubber viewForItemAtIndex:(NSInteger)index
{
    NSScrubberTextItemView *itemView = [scrubber makeItemWithIdentifier:@"ServerItem" owner:nil];
    if (!itemView) {
        itemView = [[[NSScrubberTextItemView alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)] autorelease];
        itemView.identifier = @"ServerItem";
    }
    
    NSArray *serverNames = [[ServerDataManager sharedInstance] sortedServerNames];
    if (index >= 0 && index < (NSInteger)[serverNames count]) {
        NSString *serverName = [serverNames objectAtIndex:index];
        Session *activeSession = [self activeSessionForServerName:serverName];
        
        if (activeSession) {
            itemView.textField.stringValue = [NSString stringWithFormat:@"🟢 %@", serverName];
        } else {
            itemView.textField.stringValue = [NSString stringWithFormat:@"⚡️ %@", serverName];
        }
    } else {
        itemView.textField.stringValue = @"";
    }
    
    return itemView;
}

#pragma mark - NSScrubberDelegate & NSScrubberDelegateFlowLayout

- (NSSize)scrubber:(NSScrubber *)scrubber layout:(NSScrubberFlowLayout *)layout sizeForItemAtIndex:(NSInteger)index
{
    NSArray *serverNames = [[ServerDataManager sharedInstance] sortedServerNames];
    if (index < 0 || index >= (NSInteger)[serverNames count]) {
        return NSMakeSize(80.0, 30.0);
    }
    
    NSString *serverName = [serverNames objectAtIndex:index];
    Session *activeSession = [self activeSessionForServerName:serverName];
    NSString *title = activeSession ? [NSString stringWithFormat:@"🟢 %@", serverName] : [NSString stringWithFormat:@"⚡️ %@", serverName];
    
    NSDictionary *attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:15.0] };
    NSSize textSize = [title sizeWithAttributes:attributes];
    CGFloat width = ceil(textSize.width) + 32.0;
    
    return NSMakeSize(MAX(width, 60.0), 30.0);
}

- (void)scrubber:(NSScrubber *)scrubber didSelectItemAtIndex:(NSInteger)index
{
    [self handleScrubberActionAtIndex:index];
}

- (void)scrubber:(NSScrubber *)scrubber didHighlightItemAtIndex:(NSInteger)index
{
    [self handleScrubberActionAtIndex:index];
}

- (void)handleScrubberActionAtIndex:(NSInteger)index
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (index == mLastActionIndex && (now - mLastActionTime) < 0.3) {
        return;
    }
    mLastActionIndex = index;
    mLastActionTime = now;
    
    NSArray *serverNames = [[ServerDataManager sharedInstance] sortedServerNames];
    if (index >= 0 && index < (NSInteger)[serverNames count]) {
        NSString *serverName = [serverNames objectAtIndex:index];
        [[RFBConnectionManager sharedManager] connectToSavedServerByName:serverName];
    }
}

#pragma mark - Touch Bar Actions

- (void)showConnectionWindowPressed:(id)sender
{
    [[RFBConnectionManager sharedManager] showConnectionDialog:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end
