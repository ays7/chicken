//
//  AppDelegate.m
//  Chicken of the VNC
//
//  Created by Jason Harris on 8/18/04.
//  Copyright 2004 Geekspiff. All rights reserved.
//

#import "AppDelegate.h"
#import "debug.h"
#import "KeyEquivalentManager.h"
#import "PrefController.h"
#import "ProfileManager.h"
#import "RFBConnectionManager.h"
#import "ListenerController.h"
#import "ServerDataManager.h"
#import "DockConnection.h"
#import "TouchBarController.h"
#import "ServerDataViewController.h"
#import "ServerStandAlone.h"
#import "IServerData.h"

@implementation AppDelegate

- (id) init
{
    if (self = [super init])
        dockConnections = [[NSMutableArray alloc] init];

    return self;
}

/* This will copy the Chicken of the VNC preferences file to a Chicken file, if
 * the former exists and the latter doesn't. This allows us to inherit Chicken
 * of the VNC preferences the first time we're run. This has to be called before
 * any call to NSUserDefaults. */
- (void)copyCotvncPrefs
{
    NSArray         *libDirs;
    int             i;
    NSFileManager   *fileManager = [NSFileManager defaultManager];

    libDirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                  NSUserDomainMask, YES);

    for (i = 0; i < [libDirs count]; i++) {
        NSString    *path = [libDirs objectAtIndex:i];
        NSString    *cotvncPref;
        NSString    *chickenPref;
        
        cotvncPref = [path stringByAppendingPathComponent:
                            @"Preferences/com.geekspiff.chickenofthevnc.plist"];
        chickenPref = [path stringByAppendingPathComponent:
                            @"Preferences/net.sourceforge.chicken.plist"];

        if ([fileManager fileExistsAtPath:cotvncPref]
                && ![fileManager fileExistsAtPath:chickenPref]) {
            BOOL    success;
            success = [fileManager copyItemAtPath:cotvncPref toPath:chickenPref
                                    error:nil];
            if (!success) {
                NSLog(@"Failed to copy %@ to %@", cotvncPref, chickenPref);
            }
        }
    }
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    [self copyCotvncPrefs];
	// make sure our singleton key equivalent manager is initialized, otherwise, it won't watch the frontmost window
	[KeyEquivalentManager defaultManager];
}

- (NSTouchBar *)makeTouchBar
{
    return [[TouchBarController sharedController] makeTouchBar];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	RFBConnectionManager *cm = [RFBConnectionManager sharedManager];

	if ( ! [cm runFromCommandLine] && ! [cm launchedByURL] )
		[cm runNormally];
	
    [mRendezvousMenuItem setState: [[PrefController sharedController] usesRendezvous] ? NSControlStateValueOn : NSControlStateValueOff];
	[mInfoVersionNumber setStringValue: [[[NSBundle mainBundle] infoDictionary] objectForKey: @"CFBundleVersion"]];
    if ([NSWindow respondsToSelector:@selector(setAllowsAutomaticWindowTabbing:)]) {
        [NSWindow setAllowsAutomaticWindowTabbing:NO];
    }
    if (@available(macOS 10.12.2, *)) {
        [NSApp setTouchBar:[self makeTouchBar]];
    }
}


- (IBAction)showPreferences: (id)sender
{
	[[PrefController sharedController] showWindow];
}

- (BOOL) applicationShouldHandleReopen: (NSApplication *) app hasVisibleWindows: (BOOL) visibleWindows
{
	if(!visibleWindows)
	{
		[self showConnectionDialog:nil];
		return NO;
	}
	
	return YES;
}

- (IBAction)changeRendezvousUse:(id)sender
{
	PrefController *prefs = [PrefController sharedController];
	[prefs toggleUseRendezvous: sender];
	
    [mRendezvousMenuItem setState: [prefs usesRendezvous] ? NSControlStateValueOn : NSControlStateValueOff];
}


- (IBAction)showConnectionDialog: (id)sender
{  [[RFBConnectionManager sharedManager] showConnectionDialog: nil];  }

- (IBAction)showNewConnectionDialog:(id)sender
{  [[RFBConnectionManager sharedManager] showNewConnectionDialog: nil];  }

- (IBAction)showListenerDialog: (id)sender
{  [[ListenerController sharedController] showWindow: nil];  }


- (IBAction)showProfileManager: (id)sender
{  [[ProfileManager sharedManager] showWindow: nil];  }


- (IBAction)showHelp: (id)sender
{
	NSURL *url = [NSURL URLWithString: @"https://ays7.github.io/chicken/"];
	if (url) {
		[[NSWorkspace sharedWorkspace] openURL: url];
	}
}

- (IBAction)setDiagnosticLogLevel:(id)sender
{
    NSInteger level = [sender tag];
    [[NSUserDefaults standardUserDefaults] setInteger:level forKey:@"DiagnosticLoggingLevel"];
    [[NSUserDefaults standardUserDefaults] setBool:(level > DiagnosticLogLevelNone) forKey:@"EnableDiagnosticLogging"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSString *levelName = @"None";
    if (level == DiagnosticLogLevelBasic) {
        levelName = @"Basic";
    } else if (level == DiagnosticLogLevelVerbose) {
        levelName = @"Verbose";
    }
    NSLog(@"[Chicken Fork] Diagnostic logging level set to %@", levelName);
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    if ([menuItem action] == @selector(setDiagnosticLogLevel:)) {
        DiagnosticLogLevel currentLevel = GetDiagnosticLogLevel();
        [menuItem setState:([menuItem tag] == currentLevel) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    return YES;
}


/* Dock menu-related selectors */

- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
	NSMenu              *dockMenu = [[[NSMenu alloc] init] autorelease];
    ServerDataManager   *serverManager = [ServerDataManager sharedInstance];
	NSEnumerator        *enumerator;
	NSString            *s;

	[dockMenu addItemWithTitle:NSLocalizedString(@"ConnectTo", nil)
			  action:nil
			  keyEquivalent:@""];

	enumerator = [[serverManager sortedServerNames] objectEnumerator];
	while (s = [enumerator nextObject]) {
		NSMenuItem	*item =  [dockMenu addItemWithTitle:s
										action:@selector(connectClicked:)
										keyEquivalent:@""];

		[item setTarget:self];
        [item setRepresentedObject:[serverManager getServerWithName:s]];
        [item setIndentationLevel:1];
	}

    if ([dockConnections count] > 0) {
        // Menu items for current dock-initiated connection attempts.
        [dockMenu addItem:[NSMenuItem separatorItem]];
        [dockConnections makeObjectsPerformSelector:@selector(addMenuItems:)
                withObject:dockMenu];
    }

    return dockMenu;
}	

- (void)connectClicked: (id)sender
{
    DockConnection      *conn;

    conn = [[DockConnection alloc] initWithServer:[sender representedObject]];
    [dockConnections addObject:conn];
    [conn release];
}

- (void)addDockConnection:(DockConnection *)conn
{
    [dockConnections addObject:conn];
}

- (void)removeDockConnection: (DockConnection *)conn
{
    /* This selector is called by the object conn itself. We want to make sure
     * that the object continues to exist, even though we're about to remove it
     * from our array. */
    [[conn retain] autorelease];
    [dockConnections removeObject:conn];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
    if ([[filename pathExtension] caseInsensitiveCompare:@"rdp"] == NSOrderedSame)
    {
        NSStringEncoding encoding = 0;
        NSError *error = nil;
        NSString *content = [NSString stringWithContentsOfFile:filename usedEncoding:&encoding error:&error];
        if (!content && error)
        {
            // Fallback to UTF-8 or ASCII if usedEncoding could not detect
            content = [NSString stringWithContentsOfFile:filename encoding:NSUTF8StringEncoding error:nil];
        }

        NSString *host = nil;
        int port = 3389;
        NSString *user = nil;
        NSString *domain = nil;
        int audioMode = 0; // Default: 0 = play on this computer

        if (content)
        {
            NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            for (NSString *rawLine in lines)
            {
                NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([line length] == 0 || [line hasPrefix:@"#"])
                    continue;

                if ([line hasPrefix:@"full address:s:"])
                {
                    host = [line substringFromIndex:[@"full address:s:" length]];
                }
                else if ([line hasPrefix:@"server port:i:"])
                {
                    NSString *portStr = [line substringFromIndex:[@"server port:i:" length]];
                    port = [portStr intValue];
                }
                else if ([line hasPrefix:@"username:s:"])
                {
                    user = [line substringFromIndex:[@"username:s:" length]];
                }
                else if ([line hasPrefix:@"domain:s:"])
                {
                    domain = [line substringFromIndex:[@"domain:s:" length]];
                }
                else if ([line hasPrefix:@"audiomode:i:"])
                {
                    NSString *modeStr = [line substringFromIndex:[@"audiomode:i:" length]];
                    audioMode = [modeStr intValue];
                }
            }
        }

        ServerStandAlone *server = [[ServerStandAlone alloc] init];
        [server setRemoteProtocol:RemoteProtocolRDP];
        [server setRdpAudioMode:audioMode];
        if (host)
        {
            [server setHostAndPort:host];
            if ([server port] == 0 || [server port] == 5900)
                [server setPort:port];
        }
        else
        {
            [server setPort:port];
        }

        if (domain && [domain length] > 0 && user && [user length] > 0 && [user rangeOfString:@"\\"].location == NSNotFound)
        {
            [server setUsername:[NSString stringWithFormat:@"%@\\%@", domain, user]];
        }
        else if (user)
        {
            [server setUsername:user];
        }

        [server setProfileName:@"Windows"];

        ServerDataViewController *viewCtrlr = [[ServerDataViewController alloc] initWithReleaseOnCloseOrConnect];
        [viewCtrlr setServer:server];
        [[viewCtrlr window] makeKeyAndOrderFront:self];
        [server release];
        [viewCtrlr release];
        return YES;
    }
    return NO;
}

@end
