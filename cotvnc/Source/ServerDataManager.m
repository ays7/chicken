//
//  ServerDataManager.m
//  Chicken of the VNC
//
//  Created by Jared McIntyre on Sat Jan 24 2004.
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
//

#import "ServerDataManager.h"
#import "PrefController.h"
#import "ServerFromPrefs.h"
#import "ServerFromRendezvous.h"
#import "ServerFromDiscovery.h"
#import "ChickenFork-Swift.h"
#import <AppKit/AppKit.h>

#define RFB_PREFS_LOCATION  @"Library/Preferences/cotvnc.prefs"
#define RFB_SERVER_LIST     @"ServerList"
#define RFB_GROUP_LIST		@"GroupList"
#define RFB_SAVED_SERVERS   @"SavedServers"
#define RFB_SAVED_SERVERS2  @"SavedServers2"

@interface ServerDataManager () <NetworkDiscoveryDelegate>
@end

@implementation ServerDataManager

static ServerDataManager* gInstance = nil;

+ (void)initialize
{
	[ServerDataManager setVersion:1];
}

/* Initialize an empty server list */
- (id)init
{
	if( self = [super init] )
	{
		mServers                 = [[NSMutableDictionary alloc] init];
		mGroups                  = [[NSMutableDictionary alloc] init];
		mRendezvousNameToServer  = [[NSMutableDictionary alloc] init];
		mDiscoveredKeyToServer   = [[NSMutableDictionary alloc] init];
		
		[mGroups setObject:mServers forKey:@"All"];
		[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Standard"];
		[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Rendezvous"];
		[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Discovered"];
		
		assert( nil != [mGroups objectForKey:@"All"] );
		assert( mServers == [mGroups objectForKey:@"All"] );
		assert( nil != [mGroups objectForKey:@"Standard"] );
		assert( nil != [mGroups objectForKey:@"Rendezvous"] );
		
		mServiceBrowser_VNC = nil;
		mServiceBrowser_RFB = nil;
	}
	
	return self;
}

/* Initialize from some old format for the preferences. Not sure when this was
 * used, but it pre-dates version 2.0b4. */
- (id)initWithOriginalPrefs
{
	if( self = [self init] )
	{
		NSDictionary *hostInfo = [[PrefController sharedController] hostInfo];
		NSEnumerator* hostEnumerator = [hostInfo keyEnumerator];
		NSEnumerator* objEnumerator = [hostInfo objectEnumerator];
		NSString* host;
		NSDictionary* obj;
		while( host = [hostEnumerator nextObject] )
		{
			obj = [objEnumerator nextObject];
			id<IServerData> server = [ServerFromPrefs createWithHost:host preferenceDictionary:obj];
			if( nil != server )
			{
				[mServers setObject:server forKey:[server name]];
			}
		}
	}
	
	return self;
}

/* Initialize from servers as stored by versions 2.2 and later */
- (id)initFromDictionary:(NSDictionary *)servers
{
    if (self = [self init]) {
        NSEnumerator    *e = [servers keyEnumerator];
        NSString        *name;
        NSMutableDictionary    *standServers = [mGroups objectForKey:@"Standard"];

        while (name = [e nextObject]) {
            NSDictionary    *dict = [servers objectForKey:name];
            ServerFromPrefs *server;

            server = [[ServerFromPrefs alloc] initWithName:name
                                             andDictionary:dict];
            [mServers setObject:server forKey:name];
            [standServers setObject:server forKey:name];
        }
    }

    return self;
}

- (void)dealloc
{
	NSParameterAssert( gInstance == self );

	[self save];
	gInstance = nil;
}

+ (ServerDataManager*) sharedInstance
{
	if( nil == gInstance )
	{
        NSUserDefaults  *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary    *servers = [defaults objectForKey:RFB_SAVED_SERVERS2];

        // server list format in 2.2 and later
        if (servers)
            gInstance = [[ServerDataManager alloc] initFromDictionary:servers];

        if (nil == gInstance) {
            // servers saved by 2.1 or earlier
            NSData *data = [defaults objectForKey:RFB_SAVED_SERVERS];
            if ( data )
            {
                gInstance = [NSKeyedUnarchiver unarchivedObjectOfClass:[ServerDataManager class] fromData:data error:nil];
            }
        }
		
		if( nil == gInstance )
		{
			NSString *storePath = [NSHomeDirectory() stringByAppendingPathComponent:RFB_PREFS_LOCATION];
			NSData *storeData = [NSData dataWithContentsOfFile:storePath];
			if (storeData) {
				gInstance = [NSKeyedUnarchiver unarchivedObjectOfClass:[ServerDataManager class] fromData:storeData error:nil];
			}
			if( nil == gInstance )
			{
				// Didn't find any preferences under the new serialization system,
				// load based on the old system
				gInstance = [[ServerDataManager alloc] initWithOriginalPrefs];
				
				[gInstance save];
			}
		}
		
		if( 0 == [gInstance serverCount] )
		{
			[gInstance createServerByName:NSLocalizedString(@"RFBDefaultServerName", nil)];
		}
	}
	
	return gInstance;
}

/* This is called when loading servers saved by version 2.1.x and earlier. */
- (id)initWithCoder:(NSCoder *)coder
{
	NSParameterAssert( [coder allowsKeyedCoding] );
			
	if( self = [self init] )
	{
		mServers = [coder decodeObjectForKey:RFB_SERVER_LIST];
		
		mGroups = [coder decodeObjectForKey:RFB_GROUP_LIST];
		
		if( nil == mGroups )
		{
			mGroups                  = [[NSMutableDictionary alloc] init];
			[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Standard"];
			[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Rendezvous"];
		}
		if (nil == [mGroups objectForKey:@"Discovered"]) {
			[mGroups setObject:[NSMutableDictionary dictionaryWithCapacity:1] forKey:@"Discovered"];
		}

		[mGroups setObject:mServers forKey:@"All"];
		
		assert( nil != [mGroups objectForKey:@"All"] );
		assert( mServers == [mGroups objectForKey:@"All"] );
		assert( nil != [mGroups objectForKey:@"Standard"] );
		assert( nil != [mGroups objectForKey:@"Rendezvous"] );

		
		// This next bit will fix issues where the key and the name
		// didn't always match due to a bug in the name change code.
		// Eventually this should be deleted since the bug was never
		// in a public release.
		BOOL bContinueOuter = YES;
		NSString* key;
		do
		{
			BOOL bContinueInner = YES;
			NSEnumerator* keyEnumerator = [mServers keyEnumerator];
			while( (key = [keyEnumerator nextObject]) && bContinueInner )
			{
				id<IServerData> server = [mServers objectForKey:key];
				if(  NSOrderedSame != [[server name] compare: key] )
				{
					[mServers removeObjectForKey:key];
					[mServers setObject:server forKey:[server name]];
					bContinueInner = NO;
				}
			}
			
			if( nil == key )
			{
				bContinueOuter = NO;
			}
		}while( bContinueOuter );
	}
	
    return self;
}

- (void)putServers:(NSArray *)servers inDictionary:(NSMutableDictionary *)dict
{
    NSEnumerator        *en = [servers objectEnumerator];
    PersistentServer    *server;

    while ((server = [en nextObject]) != nil)
        [dict setObject:[server propertyDict] forKey:[server saveName]];
}

- (void)saveStandardServers
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    [self putServers:[mGroups objectForKey:@"Standard"] inDictionary:dict];
    [[NSUserDefaults standardUserDefaults] setObject:dict
                                              forKey:RFB_SAVED_SERVERS2];
}

- (void)saveRendezvousServers
{
    NSDictionary            *stored;
    NSMutableDictionary     *dict;

    stored = [[NSUserDefaults standardUserDefaults]
                                objectForKey:RFB_SAVED_RENDEZVOUS_SERVERS];
    dict = [NSMutableDictionary dictionaryWithDictionary:stored];
    [self putServers:[mGroups objectForKey:@"Rendezvous"] inDictionary:dict];
    [[NSUserDefaults standardUserDefaults] setObject:dict
                                         forKey:RFB_SAVED_RENDEZVOUS_SERVERS];
}

- (void)saveDiscoveredServers
{
    NSDictionary            *stored;
    NSMutableDictionary     *dict;

    stored = [[NSUserDefaults standardUserDefaults]
                                objectForKey:RFB_SAVED_DISCOVERED_SERVERS];
    dict = [NSMutableDictionary dictionaryWithDictionary:stored];
    [self putServers:[[mGroups objectForKey:@"Discovered"] allValues] inDictionary:dict];
    [[NSUserDefaults standardUserDefaults] setObject:dict
                                         forKey:RFB_SAVED_DISCOVERED_SERVERS];
}

- (void)save
{
    [self saveStandardServers];
    [self saveRendezvousServers];
    [self saveDiscoveredServers];
}

- (void)saveRendezvousServer: (PersistentServer *)server
{
    NSUserDefaults      *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary        *immutServers;
    NSMutableDictionary *servers;

    immutServers = [defaults objectForKey:RFB_SAVED_RENDEZVOUS_SERVERS];
    servers = [NSMutableDictionary dictionaryWithDictionary:immutServers];

    [servers setObject:[server propertyDict] forKey:[server saveName]];
	[defaults setObject:servers forKey:RFB_SAVED_RENDEZVOUS_SERVERS];
}

- (unsigned) serverCount
{
	return (unsigned int)[mServers count];
}

/* Returns the number of saveable servers, i.e. excluding Rendezvous servers */
- (unsigned)saveableCount
{
    NSEnumerator    *servers = [mServers objectEnumerator];
    ServerBase      *server;
    unsigned        count = 0;
    
    while (server = [servers nextObject]) {
        if ([server isKindOfClass:[PersistentServer class]])
            count++;
    }
    return count;
}

/* Returns an array of the server names, sorted alphabetically */
- (NSArray *)sortedServerNames
{
    NSEnumerator *serverEnumerator = [mServers objectEnumerator];
	id<IServerData> server;
    NSMutableArray  *names = [[NSMutableArray alloc] init];
	
	while ( server = [serverEnumerator nextObject] )
	{
		[names addObject:[server name]];
	}
	
	[names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return names;
}

- (unsigned) groupCount
{
	return (unsigned int)[mGroups count];
}

- (NSEnumerator*) getGroupNameEnumerator
{
	return [mGroups keyEnumerator];
}

- (NSEnumerator*) getServerEnumeratorForGroupName:(NSString*)group;
{
	if( [group compare:@"Standard"] )
	{
		return [mServers objectEnumerator];
	}
	else if( [group compare:@"Rendezvous"] )
	{
		return nil;
	}
	
	return nil;
}

- (id<IServerData>)getServerWithName:(NSString*)name
{
	return [mServers objectForKey:name];
}

- (void)removeServer:(id<IServerData>)server
{	
	NSString* name;
	NSEnumerator* groupKeys = [mGroups keyEnumerator];

    // deletes keychain password, if there is one
    [server setRememberPassword:NO];
	
	while( name = [groupKeys nextObject] )
	{
		[[mGroups objectForKey:name] removeObjectForKey:[server name]];
	}
	
	assert( nil == [mServers objectForKey:[server name]] );

	[[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg
														object:self];
}

- (void)makeNameUnique:(NSMutableString*)name
{
	if(nil != [mServers objectForKey:name])
	{
		int numHelper = 0;
		NSString* newName;
		do
		{
			numHelper++;
			newName = [NSString stringWithFormat:@"%@_%d", name, numHelper];
		}while( nil != [mServers objectForKey:newName] );
		
		[name setString: newName];
	}
}

- (ServerFromPrefs *)createServerByName:(NSString*)name
{
	NSMutableString *nameHelper = [NSMutableString stringWithString:name];
	
	[self makeNameUnique:nameHelper];
	
	ServerFromPrefs* newServer = [ServerFromPrefs createWithName:nameHelper];
	[mServers setObject:newServer forKey:[newServer name]];
	[[mGroups objectForKey:@"Standard"] setObject:newServer forKey:[newServer name]];
	
	NSParameterAssert( nil != [mServers objectForKey:nameHelper] );
	NSParameterAssert( newServer == [mServers objectForKey:nameHelper] );
	
	[[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg
														object:self];
	
	return newServer;
}

- (ServerFromPrefs *)addServer:(id<IServerData>)server
{
	ServerFromPrefs *newServer = [self createServerByName:[server name]];
	NSString* nameHolder = [newServer name];
	
	[newServer copyServer: server];
	
	[newServer setName:nameHolder];
	
	return newServer;
}

- (void)validateNameChange:(NSMutableString *)name forServer:(id<IServerData>)server;
{
	BOOL insertServer = NO;
	NSMutableArray *groupsWithServer = [[NSMutableArray alloc] init];

	// Remove original server/key pair
	//
	// It is possible that the server hasn't been inserted yet, and
	// we are validating a name for a server that will be inserted.
	// If that is the case, the server we find searching on [server name]
	// will not be the same as the server.  In this case, we won't remove
	// the server from the list (because it isn't in the list yet). However,
	// if they are the same, then we are validating a name change and
	// the server needs to be removed before being added.
	if( server == [mServers objectForKey:[server name]] )
	{
		NSString* groupName;
		NSEnumerator* groupKeys = [mGroups keyEnumerator];
		while( groupName = [groupKeys nextObject] )
		{
			NSMutableDictionary *group = [mGroups objectForKey:groupName];
			if( nil != [group objectForKey:[server name]] )
			{
				[group removeObjectForKey:[server name]];
				[groupsWithServer addObject:groupName];
			}
		}

		[mServers removeObjectForKey:[server name]];
		
		insertServer = YES;
	}

	// Check to see if new name is valid and update if it isn't
	if( nil != [mServers objectForKey:name] )
	{
		NSParameterAssert( server != [mServers objectForKey:name] );
		
		[self makeNameUnique:name];
	}
	
	// Insert updated server/key pair
	if( insertServer )
	{
		NSString* groupName;
		NSEnumerator* groupNames = [groupsWithServer objectEnumerator];
		while( groupName = [groupNames nextObject] )
		{
			[[mGroups objectForKey:groupName] setObject:server forKey:name];
		}
		[mServers setObject:server forKey:name];
	}
}

- (void)useRendezvous:(bool)use
{
	if( use != mUsingRendezvous )
	{
		mUsingRendezvous = use;
		
		if( mUsingRendezvous )
		{
			NSParameterAssert( nil == mServiceBrowser_VNC );
			
			mServiceBrowser_VNC = [[NSNetServiceBrowser alloc] init];
			[mServiceBrowser_VNC setDelegate:self];
			[mServiceBrowser_VNC searchForServicesOfType:@"_vnc._tcp" inDomain:@""];
			
			NSParameterAssert( nil == mServiceBrowser_RFB );
			
			mServiceBrowser_RFB = [[NSNetServiceBrowser alloc] init];
			[mServiceBrowser_RFB setDelegate:self];
			[mServiceBrowser_RFB searchForServicesOfType:@"_rfb._tcp" inDomain:@""];
		}
		else
		{
            [self saveRendezvousServers];

			mServiceBrowser_VNC = nil;
			mServiceBrowser_RFB = nil;
			
			NSMutableDictionary *rendezvousDict = [mGroups objectForKey:@"Rendezvous"];
			NSEnumerator *rendEnum = [rendezvousDict keyEnumerator];
			NSString* host;
			while( host = [rendEnum nextObject] )
			{
				[mServers removeObjectForKey:host];
			}
			
			[rendezvousDict removeAllObjects];
			[mRendezvousNameToServer removeAllObjects];
			
			[[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg
																object:self];
		}
	}
}

- (bool)getUseRendezvous
{
	return mUsingRendezvous;
}

// Sent when browsing begins
- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser *)browser
{
    mSearching = YES;	
    //[self updateUI];
}

// Sent when browsing stops
- (void)netServiceBrowserDidStopSearch:(NSNetServiceBrowser *)browser
{
    mSearching = NO;
    //[self updateUI];	
}

// Sent if browsing fails
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
			 didNotSearch:(NSDictionary *)errorDict
{
    mSearching = NO;
    //[self handleError:[errorDict objectForKey:NSNetServicesErrorCode]];	
}

// Sent when a service appears
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
		   didFindService:(NSNetService *)aNetService
			   moreComing:(BOOL)moreComing
{
	ServerFromRendezvous* newServer = [ServerFromRendezvous createWithNetService:aNetService];
	
	// store a quick lookup list that connects the rendezvous name to the server class
	// because the server name will not necessarily match that of the service published
	[mRendezvousNameToServer setObject:newServer forKey:[aNetService name]];
	
	[mServers setObject:newServer forKey:[newServer name]];
	[[mGroups objectForKey:@"Rendezvous"] setObject:newServer forKey:[newServer name]];
	
	NSParameterAssert( nil != [mServers objectForKey:[newServer name]] );
	NSParameterAssert( nil != [mGroups objectForKey:@"Rendezvous"] );
	NSParameterAssert( nil != [[mGroups objectForKey:@"Rendezvous"] objectForKey:[newServer name]] );
	NSParameterAssert( newServer == [mServers objectForKey:[newServer name]] );
	NSParameterAssert( newServer == [[mGroups objectForKey:@"Rendezvous"] objectForKey:[newServer name]] );
	
    if(!moreComing)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg
															object:self];
	}
}

// Sent when a service disappears
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
		 didRemoveService:(NSNetService *)aNetService
			   moreComing:(BOOL)moreComing
{
	ServerFromRendezvous* serverToRemove = [mRendezvousNameToServer objectForKey:[aNetService name]];
	
	if (serverToRemove != nil)
	{
		[mRendezvousNameToServer removeObjectForKey:[aNetService name]];
		[[mGroups objectForKey:@"Rendezvous"] removeObjectForKey:[serverToRemove name]];
		[mServers removeObjectForKey:[serverToRemove name]];

		[self saveRendezvousServer:serverToRemove];
	}
	else
	{
		[mRendezvousNameToServer removeObjectForKey:[aNetService name]];
	}
    
    if(!moreComing)
    {		
        [[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg
															object:self];
    }	
}

#pragma mark - Active LAN RDP Network Scan

- (NSDictionary *)localSubnetsInfo
{
    return [[NetworkDiscoveryManager shared] localSubnetsInfo];
}

- (void)stopBonjourBrowsers
{
    [mServiceBrowser_VNC stop];
    mServiceBrowser_VNC = nil;
    [mServiceBrowser_RFB stop];
    mServiceBrowser_RFB = nil;
    mUsingRendezvous = NO;
}

- (void)startNetworkScan
{
    [self useRendezvous:NO];
    [self saveDiscoveredServers];

    NSMutableDictionary *discoveredDict = [mGroups objectForKey:@"Discovered"];
    for (NSString *key in [discoveredDict allKeys]) {
        [mServers removeObjectForKey:key];
    }
    [discoveredDict removeAllObjects];
    [mDiscoveredKeyToServer removeAllObjects];

    [[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg object:self];
    [self useRendezvous:YES];
    [[NetworkDiscoveryManager shared] startScanWithDelegate:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:NetworkScanStateChangeMsg object:self];
}

- (void)stopNetworkScan
{
    [self stopBonjourBrowsers];
    [[NetworkDiscoveryManager shared] stopScan];
    [[NSNotificationCenter defaultCenter] postNotificationName:NetworkScanStateChangeMsg object:self];
}

- (BOOL)isNetworkScanning
{
    return [[NetworkDiscoveryManager shared] isScanning];
}

- (NSString *)discoveredDisplayNameFor:(NSString *)hostName
{
    NSMutableString *candidate = [NSMutableString stringWithFormat:@"%@ (RDP)", hostName];
    [self makeNameUnique:candidate];
    return candidate;
}

- (void)discoveryDidFindHost:(NSString *)address port:(uint16_t)port initialName:(NSString *)initialName
{
    NSString *key = [NSString stringWithFormat:@"%@:%u", address, port];
    if ([mDiscoveredKeyToServer objectForKey:key] != nil) {
        return;
    }

    NSString *baseName = (initialName.length > 0) ? initialName : address;
    NSString *displayName = [self discoveredDisplayNameFor:baseName];
    ServerFromDiscovery *server = [ServerFromDiscovery createWithAddress:address
                                                                    port:(int)port
                                                             displayName:displayName];
    [mDiscoveredKeyToServer setObject:server forKey:key];
    [mServers setObject:server forKey:[server name]];
    [[mGroups objectForKey:@"Discovered"] setObject:server forKey:[server name]];

    [[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg object:self];
}

- (void)discoveryDidUpdateHost:(NSString *)address port:(uint16_t)port resolvedName:(NSString *)resolvedName
{
    NSString *key = [NSString stringWithFormat:@"%@:%u", address, port];
    ServerFromDiscovery *server = [mDiscoveredKeyToServer objectForKey:key];
    if (!server) {
        return;
    }

    NSString *oldName = [server name];
    NSString *desiredPrefix = [NSString stringWithFormat:@"%@ (RDP)", resolvedName];
    if ([oldName isEqualToString:desiredPrefix]) {
        return;
    }

    NSMutableDictionary *discoveredDict = [mGroups objectForKey:@"Discovered"];
    [mServers removeObjectForKey:oldName];
    [discoveredDict removeObjectForKey:oldName];

    NSString *newName = [self discoveredDisplayNameFor:resolvedName];
    [server updateDisplayName:newName];
    [mServers setObject:server forKey:newName];
    [discoveredDict setObject:server forKey:newName];

    [[NSNotificationCenter defaultCenter] postNotificationName:ServerListChangeMsg object:self];
}

- (void)discoveryDidUpdateProgress:(NSInteger)scanned total:(NSInteger)total
{
    NSDictionary *info = @{ @"scanned": @(scanned), @"total": @(total) };
    [[NSNotificationCenter defaultCenter] postNotificationName:NetworkScanStateChangeMsg
                                                        object:self
                                                      userInfo:info];
}

- (void)discoveryDidCompleteWithError:(NSString *)error
{
    [self stopBonjourBrowsers];
    NSDictionary *info = error ? @{ @"error": error } : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:NetworkScanStateChangeMsg
                                                        object:self
                                                      userInfo:info];
}

@end
