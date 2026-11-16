//
//  ARDAuthHelper.h
//  Chicken Fork
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ARDAuthResult : NSObject

@property (nonatomic, readonly) NSData *clientPublicKey;
@property (nonatomic, readonly) NSData *encryptedCredentials;

- (instancetype)initWithClientPublicKey:(NSData *)clientPublicKey
                   encryptedCredentials:(NSData *)encryptedCredentials;

@end

@interface ARDAuthHelper : NSObject

+ (nullable ARDAuthResult *)performDiffieHellmanWithGenerator:(NSData *)generator
                                                        prime:(NSData *)prime
                                                      peerKey:(NSData *)peerKey
                                                     username:(NSString *)username
                                                     password:(NSString *)password;

@end

NS_ASSUME_NONNULL_END
