//
//  KeyChain.m
//  Chicken of the VNC
//

#import "KeyChain.h"
#import <Security/Security.h>

static KeyChain* defaultKeyChain = nil;

@implementation KeyChain

+ (KeyChain*) defaultKeyChain {
    if (defaultKeyChain == nil)
        defaultKeyChain = [[self alloc] init];
    return defaultKeyChain;
}

- (BOOL)setGenericPassword:(NSString*)password forService:(NSString *)service account:(NSString*)account
{
    if ([service length] == 0 || [account length] == 0) {
        return NO;
    }
    
    if (!password || [password length] == 0) {
        [self removeGenericPasswordForService:service account:account];
        return YES;
    }
    
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account
    };
    
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
    
    if (status == errSecSuccess) {
        NSDictionary *attributesToUpdate = @{
            (__bridge id)kSecValueData: passwordData
        };
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributesToUpdate);
    } else {
        NSMutableDictionary *newItem = [query mutableCopy];
        newItem[(__bridge id)kSecValueData] = passwordData;
        status = SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
        [newItem release];
    }
    
    if (status != errSecSuccess) {
        NSLog(@"Couldn't save to keychain: %d", (int)status);
    }
    return status == errSecSuccess;
}

- (NSString*)genericPasswordForService:(NSString *)service account:(NSString*)account
{
    if ([service length] == 0 || [account length] == 0) {
        return @"";
    }
    
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    
    CFTypeRef dataTypeRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef);
    
    if (status == errSecSuccess && dataTypeRef != NULL) {
        NSData *passwordData = (NSData *)dataTypeRef;
        NSString *result = [[[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding] autorelease];
        return result ? result : @"";
    }
    
    return @"";
}

- (void)removeGenericPasswordForService:(NSString *)service account:(NSString*)account
{
    if ([service length] == 0 || [account length] == 0) {
        return;
    }
    
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account
    };
    
    SecItemDelete((__bridge CFDictionaryRef)query);
}

@end
