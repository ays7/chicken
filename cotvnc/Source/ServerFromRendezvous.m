//
//  ServerFromRendezvous.m
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

#import "ServerFromRendezvous.h"
#import "sys/socket.h"
#import "netinet/in.h"
#import "arpa/inet.h"
#import "Profile.h"

@implementation ServerFromRendezvous

+ (ServerFromRendezvous *)createWithNetService:(NSNetService*)service
{
	return [[ServerFromRendezvous alloc] initWithNetService:service];
}

- (id)initWithNetService:(NSNetService*)service
{
    NSDictionary* rendServerDict = [[NSUserDefaults standardUserDefaults] objectForKey:RFB_SAVED_RENDEZVOUS_SERVERS];
    NSDictionary* propertyDict = [rendServerDict objectForKey:[service name]];

    if (propertyDict)
        self = [super initFromDictionary:propertyDict];
    else
        self = [super init];

	if (self)
	{
        _host = [service name];
        _port = -1;
		
		service_ = service;
		
        _name = [service_ name];
	}
	
	return self;
}

- (void)dealloc
{
    [service_ setDelegate:nil];
}

- (bool)doYouSupport: (SUPPORT_TYPE)type
{
	switch( type )
	{
		case EDIT_ADDRESS:
		case EDIT_PORT:
		case EDIT_NAME:
			return NO;
		case EDIT_PASSWORD:
		case CONNECT:
			return YES;
	}
	
    // shouldn't get here, but just in case...
	return NO;
}

- (void)resolveWithDelegate: (id <ServerDelegate>)aDelegate
{
    delegate_ = aDelegate;
    [service_ setDelegate:self];
    [service_ resolveWithTimeout: 5.0];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict
{
    [delegate_ serverDidNotResolve];
    delegate_ = nil;
	_host = NSLocalizedString(@"AddressResolveFailed", nil);
	
	[[NSNotificationCenter defaultCenter] postNotificationName:ServerChangeMsg
														object:self];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender
{
    int i;
    id<ServerDelegate> deleg = delegate_;

    delegate_ = nil;

    /* NSNetService resolution can produce multiple addresses, which result in
     * multiple callbacks here. We arbitrarily decide that we're only going to
     * look at the first one and so we have to stop further resolution. Maybe
     * not the best thing, but better than multiple connections. */
    [service_ stop];
    
    for (i=0;i<[[service_ addresses] count];i++) {
        struct sockaddr_in *sockAddr = (struct sockaddr_in*)[[[service_ addresses] objectAtIndex:i] bytes];
        struct in_addr sinAddr = sockAddr->sin_addr;
        if (sinAddr.s_addr != 0)
        {
            int      resPort = ntohs(sockAddr->sin_port);
            NSString *resHost;

            resHost = [NSString stringWithUTF8String:inet_ntoa(sinAddr)];
            [deleg serverResolvedWithHost:resHost port: resPort];
            return;
        }
    }
    [deleg serverDidNotResolve];
}

- (NSString *)keychainServiceName
{
    return @"Chicken-zeroconf";
}

- (NSString *)saveName
{
    return [service_ name];
}

@end
