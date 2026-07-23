/* RFBHandshaker.m created by helmut on Tue 16-Jun-1998 */

/* Copyright (C) 1998-2000  Helmut Maierhofer <helmut.maierhofer@chello.at>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 */

#import "RFBHandshaker.h"
#import "RFBServerInitReader.h"
#import "CARD8Reader.h"
#import "CARD16Reader.h"
#import "CARD32Reader.h"
#import "ByteBlockReader.h"
#import "RFBStringReader.h"
#import "Chicken-Swift.h"
#import "debug.h"

/* This handles the handshaking messages from the server. */
@implementation RFBHandshaker

- (id)initWithConnection: (RFBConnection *)aConnection;
{
	if (self = [super init]) {
        connection = aConnection;
        connFailedReader = [[RFBStringReader alloc] initTarget:self action:@selector(connFailed:) connection:connection];
		challengeReader = [[ByteBlockReader alloc] initTarget:self action:@selector(challenge:) size:CHALLENGESIZE];
		authResultReader = [[CARD32Reader alloc] initTarget:self action:@selector(setAuthResult:)];
        serverInitReader = nil;
	}
    return self;
}

- (void)dealloc
{
    [connFailedReader release];
    [challengeReader release];
    [authResultReader release];
    [serverInitReader release];
    [vncAuthChallenge release];
    [ardGenerator release];
    [ardPrime release];
    [ardPeerKey release];
    [super dealloc];
}

- (void)handshake
{
    char clientData[sz_rfbProtocolVersionMsg + 1];
	int protocolMinorVersion = [connection protocolMinorVersion];

	sprintf(clientData, rfbProtocolVersionFormat, rfbProtocolMajorVersion, protocolMinorVersion);
    [connection writeBytes:(unsigned char*)clientData length:sz_rfbProtocolVersionMsg];
		
	if (protocolMinorVersion >= 7) {
        CARD8Reader *authCountReader;

		authCountReader = [[CARD8Reader alloc] initTarget:self action:@selector(setAuthCount:)];
		[connection setReader:authCountReader];
        [authCountReader release];
    } else {
        CARD32Reader    *authTypeReader;

		authTypeReader = [[CARD32Reader alloc] initTarget:self action:@selector(setAuthType:)];
		[connection setReader:authTypeReader];
        [authTypeReader release];
    }
}

- (void)sendClientInit
{
    unsigned char shared = [connection connectShared] ? 1 : 0;
    DiagnosticLog(DiagnosticLogLevelBasic, @"Sending ClientInit byte (shared=%d)...", shared);

    [connection writeBytes:&shared length:1];
    [serverInitReader release];
    serverInitReader = [[RFBServerInitReader alloc] initWithConnection: connection andHandshaker: self];
    [serverInitReader readServerInit];
}

// Protocol 3.7+
- (void)setAuthCount:(NSNumber*)authCount {
	if ([authCount intValue] == 0) {
        [connFailedReader readString];
	}
	else {
        ByteBlockReader *authTypeArrayReader;
		authTypeArrayReader = [[ByteBlockReader alloc] initTarget:self action:@selector(setAuthArray:) size:[authCount intValue]];
		[connection setReader:authTypeArrayReader];
        [authTypeArrayReader release];
	}
}

// Protocol 3.7+
- (void)setAuthArray:(NSData*)authTypeArray {
	// The server is giving us a choice of auth types, we'll take the first one that we can handle
	int index=0;
	const char *bytes=[authTypeArray bytes];
	unsigned char availableAuthType=0;
	NSString *errorStr = nil;

	DiagnosticLog(DiagnosticLogLevelBasic, @"Server offered %lu security type(s)", (unsigned long)[authTypeArray length]);

	while (index < [authTypeArray length]) {
		availableAuthType = bytes[index++];
		DiagnosticLog(DiagnosticLogLevelBasic, @"Server security type choice #%d: %u", index, availableAuthType);
		
		switch (availableAuthType) {
			case rfbNoAuth: {
				DiagnosticLog(DiagnosticLogLevelBasic, @"Selected Security Type: NoAuth (1)");
				[connection writeBytes:&availableAuthType length:1];
				
				if ([connection protocolMinorVersion] >= 8) // For 3.8+ we need to get a result back from the server
					[connection setReader: authResultReader];
				else // For 3.7 we continue on with Client Init
					[self sendClientInit];
				
				return;
			}
			case rfbVncAuth: {
				DiagnosticLog(DiagnosticLogLevelBasic, @"Selected Security Type: VNCAuth (2)");
				[connection writeBytes:&availableAuthType length:1];
				[connection setReader:challengeReader];
				return;
			}
			case 30: {
				DiagnosticLog(DiagnosticLogLevelBasic, @"Selected Security Type: ARD (30). Checking credentials...");
				[connection setIsAppleServer:YES];
				if ([connection username] == nil || [connection password] == nil) {
					DiagnosticLog(DiagnosticLogLevelBasic, @"Missing credentials for ARD (user=%@, pass=%@). Prompting user before starting DH exchange...",
						[connection username] ? @"set" : @"nil", [connection password] ? @"set" : @"nil");
					waitingForArdCredentials = YES;
					[connection promptForUsernameAndPassword];
					return;
				}
				[self startArdDhExchange];
				return;
			}
			default: {
				if (!errorStr)
					errorStr = [NSString stringWithFormat:NSLocalizedString( @"UnknownAuthType", nil ),
						[NSNumber numberWithChar:availableAuthType]]; 
				else
					errorStr = [errorStr stringByAppendingFormat:@", %@", [NSNumber numberWithChar:availableAuthType]];

			}
		}
	}

	// No valid auth type found
	DiagnosticLog(DiagnosticLogLevelBasic, @"No supported security type found among server options.");
	availableAuthType= 0;
	[connection writeBytes:&availableAuthType length:1];
	[connection terminateConnection:errorStr];
}

- (void)startArdDhExchange
{
	DiagnosticLog(DiagnosticLogLevelBasic, @"Writing ARD choice byte 30...");
	unsigned char typeByte = 30;
	[connection writeBytes:&typeByte length:1];
	ByteBlockReader *genReader = [[ByteBlockReader alloc] initTarget:self action:@selector(gotArdGenerator:) size:2];
	[connection setReader:genReader];
	[genReader release];
}

- (void)gotArdGenerator:(NSData *)data
{
    DiagnosticLog(DiagnosticLogLevelBasic, @"Got ARD generator (%lu bytes)", (unsigned long)[data length]);
    [ardGenerator release];
    ardGenerator = [[NSData dataWithData:data] retain];
    CARD16Reader *sizeReader = [[CARD16Reader alloc] initTarget:self action:@selector(gotArdKeySize:)];
    [connection setReader:sizeReader];
    [sizeReader release];
}

- (void)gotArdKeySize:(NSNumber *)size
{
    ardKeySize = [size unsignedIntValue];
    DiagnosticLog(DiagnosticLogLevelBasic, @"Got ARD keySize: %d bytes (%d bits)", ardKeySize, ardKeySize * 8);
    ByteBlockReader *primeReader = [[ByteBlockReader alloc] initTarget:self action:@selector(gotArdPrime:) size:ardKeySize];
    [connection setReader:primeReader];
    [primeReader release];
}

- (void)gotArdPrime:(NSData *)data
{
    DiagnosticLog(DiagnosticLogLevelBasic, @"Got ARD prime (%lu bytes)", (unsigned long)[data length]);
    [ardPrime release];
    ardPrime = [[NSData dataWithData:data] retain];
    ByteBlockReader *peerKeyReader = [[ByteBlockReader alloc] initTarget:self action:@selector(gotArdPeerKey:) size:ardKeySize];
    [connection setReader:peerKeyReader];
    [peerKeyReader release];
}

- (void)gotArdPeerKey:(NSData *)data
{
    DiagnosticLog(DiagnosticLogLevelBasic, @"Got ARD peerKey (%lu bytes)", (unsigned long)[data length]);
    [ardPeerKey release];
    ardPeerKey = [[NSData dataWithData:data] retain];
    [self performArdAuth];
}

- (void)performArdAuth
{
    NSString *user = [connection username];
    NSString *pass = [connection password];

    if (user == nil || pass == nil) {
        DiagnosticLog(DiagnosticLogLevelBasic, @"Missing credentials (user=%@, pass=%@). Prompting user...", user ? @"set" : @"nil", pass ? @"set" : @"nil");
        waitingForArdCredentials = YES;
        [connection promptForUsernameAndPassword];
        return;
    }

    DiagnosticLog(DiagnosticLogLevelBasic, @"Executing ARD Diffie-Hellman calculation for user '%@'...", user);
    ARDAuthResult *result = [ARDAuthHelper performDiffieHellmanWithGenerator:ardGenerator
                                                                       prime:ardPrime
                                                                     peerKey:ardPeerKey
                                                                    username:user
                                                                    password:pass];
    if (!result) {
        DiagnosticLog(DiagnosticLogLevelBasic, @"ARDAuthHelper performDiffieHellman returned nil (calculation failed).");
        [connection terminateConnection:NSLocalizedString(@"AuthenticationFailed", nil)];
        return;
    }

    NSMutableData *payload = [NSMutableData dataWithCapacity:128 + ardKeySize];
    [payload appendData:[result encryptedCredentials]];
    [payload appendData:[result clientPublicKey]];

    DiagnosticLog(DiagnosticLogLevelBasic, @"Sending %lu-byte combined authentication payload (ciphertext + client public key) to server...", (unsigned long)[payload length]);
    [connection writeBytes:(unsigned char *)[payload bytes] length:(unsigned int)[payload length]];

    DiagnosticLog(DiagnosticLogLevelBasic, @"Sent authentication payload. Setting reader to authResultReader...");
    [connection setReader:authResultReader];
    triedPassword = YES;
}

- (void)setAuthType:(NSNumber*)authType
{
    switch([authType unsignedIntValue]) {
        case rfbConnFailed:
            [connFailedReader readString];
            break;
        case rfbNoAuth:
            [self sendClientInit];
            break;
        case rfbVncAuth:
            [connection setReader:challengeReader];
            break;
        default:
		{
			NSString *errorStr = NSLocalizedString( @"UnknownAuthType", nil );
			errorStr = [NSString stringWithFormat:errorStr, authType];
            [connection terminateConnection:errorStr];
            break;
		}
    }
}

- (void)challenge:(NSData*)theChallenge
{
    unsigned char bytes[CHALLENGESIZE];

    if ([connection password] == nil) {
        [connection promptForPassword];
        [vncAuthChallenge autorelease];
        /* Note that theChallenge uses strictly temporary memory, so we can't
         * just retain, we have to copy. */
        vncAuthChallenge = [[NSData dataWithData:theChallenge] retain];
        return;
    }

    [theChallenge getBytes:bytes length:CHALLENGESIZE];
    vncEncryptBytes(bytes, (char*)[[connection password] UTF8String]);
    [connection writeBytes:bytes length:CHALLENGESIZE];
    [connection setReader:authResultReader];
    triedPassword = YES;
}

- (void)gotPassword
{
    if (vncAuthChallenge) {
        [self challenge:vncAuthChallenge];
        [vncAuthChallenge release];
        vncAuthChallenge = nil;
    } else if (waitingForArdCredentials) {
        waitingForArdCredentials = NO;
        if (ardPeerKey) {
            [self performArdAuth];
        } else {
            [self startArdDhExchange];
        }
    }
}

- (void)setAuthResult:(NSNumber*)theResult
{
    NSString *errorStr;
    DiagnosticLog(DiagnosticLogLevelBasic, @"setAuthResult received result code %u (0 = OK, 1 = Failed, 2 = TooMany)", [theResult unsignedIntValue]);

    switch([theResult unsignedIntValue]) {
        case rfbVncAuthOK:
            DiagnosticLog(DiagnosticLogLevelBasic, @"Authentication SUCCESS! Sending ClientInit...");
            [self sendClientInit];
            return;
        case rfbVncAuthFailed:
            DiagnosticLog(DiagnosticLogLevelBasic, @"Authentication FAILED (rfbVncAuthFailed = 1).");
            if ([connection protocolMinorVersion] >= 8) {
                 // 3.8+ We get an error return string (unlocalized)
                [connFailedReader readString];
                return;
            }
            else {
                errorStr = @"";
            }
            break;
        case rfbVncAuthTooMany:
            /* According to the spec, this should never happen, because we don't
             * specify the Tight security type. */
            DiagnosticLog(DiagnosticLogLevelBasic, @"Authentication FAILED (rfbVncAuthTooMany = 2).");
            errorStr = NSLocalizedString( @"AuthenticationFailedTooMany", nil );
            [connection terminateConnection:errorStr];
            return;
        default:
            DiagnosticLog(DiagnosticLogLevelBasic, @"Authentication returned unknown result code %u.", [theResult unsignedIntValue]);
            errorStr = NSLocalizedString( @"UnknownAuthResult", nil );
            errorStr = [NSString stringWithFormat:errorStr, theResult];
            break;
    }
    if (triedPassword)
        [connection authenticationFailed:errorStr];
    else {
        errorStr = NSLocalizedString(@"AuthenticationFailed", nil);
        [connection terminateConnection:errorStr];
    }
}

- (void)setServerInit:(ServerInitMessage*)serverMsg
{
    DiagnosticLog(DiagnosticLogLevelBasic, @"ServerInit received. Handshake completed successfully!");
    DiagnosticLog(DiagnosticLogLevelBasic, @"ServerInit details: size=(%.0f x %.0f), name='%@'",
           [serverMsg size].width, [serverMsg size].height, [serverMsg name]);
    rfbPixelFormat *pf = [serverMsg pixelFormatData];
    if (pf) {
        DiagnosticLog(DiagnosticLogLevelBasic, @"ServerInit pixel format: bpp=%d, depth=%d, bigEndian=%d, trueColour=%d, redMax=%d, greenMax=%d, blueMax=%d, redShift=%d, greenShift=%d, blueShift=%d",
               pf->bitsPerPixel, pf->depth, pf->bigEndian, pf->trueColour,
               pf->redMax, pf->greenMax, pf->blueMax,
               pf->redShift, pf->greenShift, pf->blueShift);
    }
    NSString *name = [serverMsg name];
    if (name) {
        NSString *lowerName = [name lowercaseString];
        if ([lowerName containsString:@"mac"] ||
            [lowerName containsString:@"apple"] ||
            [lowerName containsString:@"os x"] ||
            [lowerName containsString:@"ard"] ||
            [lowerName containsString:@"oldthing"]) {
            DiagnosticLog(DiagnosticLogLevelBasic, @"Detected Apple server from desktop name '%@'. Disabling Extended Clipboard.", name);
            [connection setIsAppleServer:YES];
        }
    }
    [connection start:serverMsg];
}

- (void)connFailed:(NSString*)theReason
{
    NSString *errorStr;
    DiagnosticLog(DiagnosticLogLevelBasic, @"Server reported connection failure: %@", theReason);

    errorStr = [NSString stringWithFormat:@"%@: %@",
                        NSLocalizedString(@"ServerReports", nil),
                        theReason];
    if (triedPassword)
        [connection authenticationFailed:errorStr];
    else
        [connection terminateConnection:errorStr];
}

@end
