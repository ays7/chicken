//
//  ServerFromDiscovery.m
//  Chicken Fork
//

#import "ServerFromDiscovery.h"

@implementation ServerFromDiscovery

+ (ServerFromDiscovery *)createWithAddress:(NSString *)address
                                      port:(int)port
                               displayName:(NSString *)displayName
{
    return [[ServerFromDiscovery alloc] initWithAddress:address
                                                   port:port
                                            displayName:displayName];
}

- (instancetype)initWithAddress:(NSString *)address
                           port:(int)port
                    displayName:(NSString *)displayName
{
    NSString *key = [NSString stringWithFormat:@"%@:%d", address, port];
    NSDictionary *savedDict = [[NSUserDefaults standardUserDefaults] objectForKey:RFB_SAVED_DISCOVERED_SERVERS];
    NSDictionary *propertyDict = [savedDict objectForKey:key];

    if (propertyDict) {
        self = [super initFromDictionary:propertyDict];
    } else {
        self = [super init];
    }

    if (self) {
        saveKey_ = [key copy];
        _host = [address copy];
        _port = port;
        _remoteProtocol = RemoteProtocolRDP;
        _name = [displayName copy];
    }

    return self;
}

- (void)updateDisplayName:(NSString *)displayName
{
    if (![_name isEqualToString:displayName]) {
        _name = [displayName copy];
        [[NSNotificationCenter defaultCenter] postNotificationName:ServerChangeMsg object:self];
    }
}

- (bool)doYouSupport:(SUPPORT_TYPE)type
{
    switch (type) {
        case EDIT_ADDRESS:
        case EDIT_PORT:
        case EDIT_NAME:
            return NO;
        case EDIT_PASSWORD:
        case CONNECT:
            return YES;
    }
    return NO;
}

- (void)resolveWithDelegate:(id<ServerDelegate>)aDelegate
{
    [aDelegate serverResolvedWithHost:_host port:_port];
}

- (NSString *)keychainServiceName
{
    return @"Chicken-discovery";
}

- (NSString *)saveName
{
    return saveKey_;
}

@end
