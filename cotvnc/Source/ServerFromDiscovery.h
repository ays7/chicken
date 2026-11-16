//
//  ServerFromDiscovery.h
//  Chicken Fork
//

#import <Foundation/Foundation.h>
#import "PersistentServer.h"
#import "IServerData.h"

#define RFB_SAVED_DISCOVERED_SERVERS @"RFB_SAVED_DISCOVERED_SERVERS"

@interface ServerFromDiscovery : PersistentServer
{
    NSString *saveKey_;
}

+ (ServerFromDiscovery *)createWithAddress:(NSString *)address
                                      port:(int)port
                               displayName:(NSString *)displayName;

- (instancetype)initWithAddress:(NSString *)address
                           port:(int)port
                    displayName:(NSString *)displayName;

- (void)updateDisplayName:(NSString *)displayName;
- (bool)doYouSupport:(SUPPORT_TYPE)type;

@end
