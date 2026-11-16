//
//  ARDAuthHelper.m
//  Chicken Fork
//
//  Fast ARD (Security Type 30) Diffie-Hellman authentication using OpenSSL BIGNUM.
//

#import "ARDAuthHelper.h"
#import "debug.h"
#import <CommonCrypto/CommonCryptor.h>
#import <Security/SecRandom.h>
#import <openssl/bn.h>
#import <openssl/evp.h>

@implementation ARDAuthResult

- (instancetype)initWithClientPublicKey:(NSData *)clientPublicKey
                   encryptedCredentials:(NSData *)encryptedCredentials
{
    self = [super init];
    if (self) {
        _clientPublicKey = [clientPublicKey copy];
        _encryptedCredentials = [encryptedCredentials copy];
    }
    return self;
}

@end

@implementation ARDAuthHelper

+ (nullable ARDAuthResult *)performDiffieHellmanWithGenerator:(NSData *)generator
                                                        prime:(NSData *)prime
                                                      peerKey:(NSData *)peerKey
                                                     username:(NSString *)username
                                                     password:(NSString *)password
{
    int keyLength = (int)[prime length];
    if (keyLength <= 0 || [generator length] == 0 || [peerKey length] == 0) {
        return nil;
    }

    DiagnosticLog(DiagnosticLogLevelBasic, @"ARDAuthHelper: Starting OpenSSL DH exchange (keyLength=%d bytes)...", keyLength);

    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *bnPrime = BN_bin2bn([prime bytes], keyLength, NULL);
    BIGNUM *bnGen = BN_bin2bn([generator bytes], (int)[generator length], NULL);
    BIGNUM *bnPeer = BN_bin2bn([peerKey bytes], (int)[peerKey length], NULL);
    BIGNUM *bnPriv = BN_new();
    BIGNUM *bnPub = BN_new();
    BIGNUM *bnSecret = BN_new();

    if (!ctx || !bnPrime || !bnGen || !bnPeer || !bnPriv || !bnPub || !bnSecret) {
        BN_free(bnSecret);
        BN_free(bnPub);
        BN_free(bnPriv);
        BN_free(bnPeer);
        BN_free(bnGen);
        BN_free(bnPrime);
        BN_CTX_free(ctx);
        return nil;
    }

    // Generate non-zero private exponent < prime
    BOOL ok = NO;
    for (int attempt = 0; attempt < 1000; attempt++) {
        if (BN_rand_range(bnPriv, bnPrime) == 1 && !BN_is_zero(bnPriv)) {
            ok = YES;
            break;
        }
    }

    if (ok) {
        ok = (BN_mod_exp(bnPub, bnGen, bnPriv, bnPrime, ctx) == 1) &&
             (BN_mod_exp(bnSecret, bnPeer, bnPriv, bnPrime, ctx) == 1);
    }

    NSMutableData *pubData = nil;
    NSMutableData *secretData = nil;
    if (ok) {
        pubData = [NSMutableData dataWithLength:keyLength];
        secretData = [NSMutableData dataWithLength:keyLength];
        if (BN_bn2binpad(bnPub, [pubData mutableBytes], keyLength) != keyLength ||
            BN_bn2binpad(bnSecret, [secretData mutableBytes], keyLength) != keyLength) {
            ok = NO;
        }
    }

    BN_clear_free(bnSecret);
    BN_clear_free(bnPriv);
    BN_free(bnPub);
    BN_free(bnPeer);
    BN_free(bnGen);
    BN_free(bnPrime);
    BN_CTX_free(ctx);

    if (!ok) {
        DiagnosticLog(DiagnosticLogLevelBasic, @"ARDAuthHelper: OpenSSL DH calculation failed.");
        return nil;
    }

    // AES-128 key = MD5(shared_secret)
    unsigned char aesKey[16];
    unsigned int mdLen = 0;
    if (EVP_Digest([secretData bytes], [secretData length], aesKey, &mdLen, EVP_md5(), NULL) != 1 || mdLen != 16) {
        OPENSSL_cleanse([secretData mutableBytes], [secretData length]);
        return nil;
    }
    OPENSSL_cleanse([secretData mutableBytes], [secretData length]);

    // 128-byte credentials block: 64-byte username + 64-byte password, NUL-terminated, random-padded
    uint8_t creds[128];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(creds), creds) != errSecSuccess) {
        OPENSSL_cleanse(aesKey, sizeof(aesKey));
        return nil;
    }

    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *cleanUser = [username stringByTrimmingCharactersInSet:ws];
    NSString *cleanPass = [password stringByTrimmingCharactersInSet:ws];

    NSData *userUtf8 = [cleanUser dataUsingEncoding:NSUTF8StringEncoding];
    NSData *passUtf8 = [cleanPass dataUsingEncoding:NSUTF8StringEncoding];
    size_t userLen = MIN((size_t)[userUtf8 length], (size_t)63);
    size_t passLen = MIN((size_t)[passUtf8 length], (size_t)63);

    if (userLen > 0) memcpy(creds, [userUtf8 bytes], userLen);
    creds[userLen] = 0;

    if (passLen > 0) memcpy(creds + 64, [passUtf8 bytes], passLen);
    creds[64 + passLen] = 0;

    uint8_t ciphertext[128];
    size_t outLen = 0;
    CCCryptorStatus ccStatus = CCCrypt(kCCEncrypt,
                                       kCCAlgorithmAES,
                                       kCCOptionECBMode,
                                       aesKey,
                                       sizeof(aesKey),
                                       NULL,
                                       creds,
                                       sizeof(creds),
                                       ciphertext,
                                       sizeof(ciphertext),
                                       &outLen);
    OPENSSL_cleanse(aesKey, sizeof(aesKey));
    OPENSSL_cleanse(creds, sizeof(creds));

    if (ccStatus != kCCSuccess || outLen != sizeof(ciphertext)) {
        DiagnosticLog(DiagnosticLogLevelBasic, @"ARDAuthHelper: AES-128-ECB encryption failed (%d).", (int)ccStatus);
        return nil;
    }

    DiagnosticLog(DiagnosticLogLevelBasic, @"ARDAuthHelper: OpenSSL DH exchange completed.");
    return [[ARDAuthResult alloc] initWithClientPublicKey:pubData
                                     encryptedCredentials:[NSData dataWithBytes:ciphertext length:sizeof(ciphertext)]];
}

@end
