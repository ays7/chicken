/* RFBProtocol.m created by helmut on Tue 16-Jun-1998 */

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

#import "RFBProtocol.h"
#import "CARD8Reader.h"
#import "debug.h"
#import "FrameBuffer.h"
#import "FrameBufferUpdateReader.h"
#import "PrefController.h"
#import "Profile.h"
#import "RFBServerInitReader.h"
#import "RFBConnection.h"
#import "ServerCutTextReader.h"
#import "SetColorMapEntriesReader.h"

/* This class essentially handles all messages from the server once the initial
 * handshaking has been completed. It also sends the initial messages with the
 * supported encodings and the pixel format to the server. */
@implementation RFBProtocol

- (id)initWithConnection:(RFBConnection*)aConnection serverInfo:(id)info
{
    if (self = [super init]) {
        connection = aConnection;
        DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol: Initializing post-handshake RFB protocol handling...");
       
        [self setPixelFormat:[info pixelFormatData]];

        [self setEncodings];
		typeReader = [[CARD8Reader alloc] initTarget:self action:@selector(receiveType:)];
        msgTypeReader[rfbFramebufferUpdate] = [[FrameBufferUpdateReader alloc]
                initWithProtocol:self connection:connection];
        msgTypeReader[rfbSetColourMapEntries] = [[SetColorMapEntriesReader alloc] initWithProtocol:self connection:connection];
        msgTypeReader[rfbBell] = nil;
        msgTypeReader[rfbServerCutText] = [[ServerCutTextReader alloc]
                initWithProtocol:self connection:connection];

        DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol: Setting socket reader to typeReader (CARD8Reader)...");
        [connection setReader: typeReader];

        [[NSNotificationCenter defaultCenter] addObserver:self
                 selector:@selector(encodingsChanged:)
                     name:ProfileEncodingsChangedMsg
                   object:[connection profile]];
	}
    return self;
}

- (void)dealloc
{
    int i;

    [typeReader release];
    for(i=0; i<=MAX_MSGTYPE; i++) {
        [msgTypeReader[i] release];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

/* Sends the list of supported encodings to the server. Note that it only
 * buffers the message, without actually writing it. It is assumed that a
 * subsequent message will be written without buffering. */
- (void)setEncodings
{
    Profile* profile = [connection profile];
    CARD16 i;
    CARD16 l = [profile numEnabledEncodingsIfViewOnly:[connection viewOnly]];
    rfbSetEncodingsMsg msg;
    memset(&msg, 0, sizeof(msg));

    msg.type = rfbSetEncodings;
    msg.nEncodings = htons(l);
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol sendType: sent client message type %u (rfbSetEncodings)", rfbSetEncodings);
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol setEncodings: sending %d encodings...", l);
    [connection writeBufferedBytes:(unsigned char*)&msg length:sizeof(msg)];

    for(i=0; i<l; i++) {
        CARD32  encVal = [profile encodingAtIndex:i];
        CARD32  enc = htonl(encVal);
        DiagnosticLog(DiagnosticLogLevelBasic, @"  Encoding #%d: %u (0x%X)", i, encVal, encVal);
        [connection writeBufferedBytes:(unsigned char*)&enc
                                length:sizeof(CARD32)];
    }
}

- (void)encodingsChanged:(NSNotification *)notif
{
    [self setEncodings];
    [connection writeBuffer];
}

/* Sends the pixel format to the server. Note that it buffers without writing.
 * It is assumed that a later message will do a non-buffered write. */
- (void)setPixelFormat:(rfbPixelFormat*)aFormat
{
    Profile* profile = [connection profile];
    rfbSetPixelFormatMsg	msg;
    memset(&msg, 0, sizeof(msg));

    msg.type = rfbSetPixelFormat;
    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol sendType: sent client message type %u (rfbSetPixelFormat)", rfbSetPixelFormat);
    aFormat->trueColour = YES;
    if([profile useServerNativeFormat]) {
        if(!aFormat->redMax || !aFormat->bitsPerPixel) {
            NSLog(@"Server proposes invalid format: redMax = %d, bitsPerPixel = %d, using local format",
                  aFormat->redMax, aFormat->bitsPerPixel);
            [[PrefController sharedController] getLocalPixelFormat:aFormat];
            aFormat->bigEndian = [FrameBuffer bigEndian];
        }
    } else {
       	[profile getPixelFormat:aFormat];
        aFormat->bigEndian = [FrameBuffer bigEndian];
    }

    DiagnosticLog(DiagnosticLogLevelBasic, @"RFBProtocol setPixelFormat: bpp=%d depth=%d bigEndian=%d trueColour=%d redMax=%d greenMax=%d blueMax=%d redShift=%d greenShift=%d blueShift=%d",
           aFormat->bitsPerPixel, aFormat->depth, aFormat->bigEndian, aFormat->trueColour,
           aFormat->redMax, aFormat->greenMax, aFormat->blueMax,
           aFormat->redShift, aFormat->greenShift, aFormat->blueShift);
    
    memcpy(&msg.format, aFormat, sizeof(rfbPixelFormat));
    msg.format.redMax = htons(msg.format.redMax);
    msg.format.greenMax = htons(msg.format.greenMax);
    msg.format.blueMax = htons(msg.format.blueMax);
    [connection writeBufferedBytes:(unsigned char*)&msg
                            length:sz_rfbSetPixelFormatMsg];
}

- (FrameBufferUpdateReader*)frameBufferUpdateReader
{
    return msgTypeReader[rfbFramebufferUpdate];
}

- (void)setFrameBuffer:(FrameBuffer *)aBuffer
{
    [msgTypeReader[rfbFramebufferUpdate] setFrameBuffer:aBuffer];
}

- (void)messageReaderDone
{
    [connection setReader:typeReader];
}

- (void)receiveType:(NSNumber*)type
{
    unsigned t = [type unsignedIntValue];
    DiagnosticLogLevel reqLevel = (t == 0) ? DiagnosticLogLevelVerbose : DiagnosticLogLevelBasic;
    if (IsDiagnosticLoggingEnabled(reqLevel)) {
        NSString *typeName = @"Unknown";
        switch (t) {
            case rfbFramebufferUpdate:   typeName = @"rfbFramebufferUpdate"; break;
            case rfbSetColourMapEntries: typeName = @"rfbSetColourMapEntries"; break;
            case rfbBell:                typeName = @"rfbBell"; break;
            case rfbServerCutText:       typeName = @"rfbServerCutText"; break;
        }
        DiagnosticLog(reqLevel, @"RFBProtocol receiveType: received server message type %u (%@)", t, typeName);
    }

    if(t > MAX_MSGTYPE) {
        NSString    *lastEnc = nil;
        NSString    *errorStr;

        if (lastMessage == rfbFramebufferUpdate)
            lastEnc = [msgTypeReader[rfbFramebufferUpdate] lastEncodingName];

        if (lastEnc) {
            NSString    *fmt;
            
            fmt = NSLocalizedString(@"UnknownMessageTypeLastEncoding", nil);
            errorStr = [NSString stringWithFormat:fmt, type, lastEnc];
        } else {
            NSString    *fmt = NSLocalizedString(@"UnknownMessageType", nil);
            errorStr = [NSString stringWithFormat:fmt, type];
        }
        [connection terminateConnection:errorStr];
    } else if(t == rfbBell) {
        NSBeep();
        [connection setReader:typeReader];
    } else {
        [msgTypeReader[t] readMessage];
    }

    lastMessage = t;
}

@end
