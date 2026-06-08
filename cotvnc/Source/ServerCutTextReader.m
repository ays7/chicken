/* ServerCutTextReader.m created by helmut on Wed 17-Jun-1998 */

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

#import "ServerCutTextReader.h"
#import "RFBStringReader.h"
#import "ByteBlockReader.h"
#import "CARD32Reader.h"
#import "RFBConnection.h"
#import "RFBProtocol.h"
#import <zlib.h>

static NSData *decompressZlib(NSData *compressedData) {
    if ([compressedData length] == 0) return compressedData;
    
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)[compressedData bytes];
    strm.avail_in = (uInt)[compressedData length];
    
    int initStatus = inflateInit(&strm);
    if (initStatus != Z_OK) {
        NSLog(@"decompressZlib: inflateInit failed with status %d", initStatus);
        return nil;
    }
    
    NSMutableData *decompressed = [NSMutableData dataWithCapacity:[compressedData length] * 2];
    unsigned char buffer[4096];
    int status = Z_OK;
    
    while (strm.avail_in > 0) {
        strm.next_out = buffer;
        strm.avail_out = sizeof(buffer);
        status = inflate(&strm, Z_SYNC_FLUSH);
        
        if (status == Z_OK || status == Z_STREAM_END) {
            [decompressed appendBytes:buffer length:(sizeof(buffer) - strm.avail_out)];
        } else if (status == Z_BUF_ERROR) {
            if (strm.avail_in == 0) {
                break;
            }
        } else {
            NSLog(@"decompressZlib: inflate failed with status %d", status);
            break;
        }
        
        if (status == Z_STREAM_END) {
            break;
        }
    }
    
    inflateEnd(&strm);
    
    if (strm.avail_in == 0 && [decompressed length] > 0) {
        return decompressed;
    }
    
    NSLog(@"decompressZlib: failed to decompress. avail_in: %u, decompressed length: %lu, status: %d", 
          strm.avail_in, (unsigned long)[decompressed length], status);
    return nil;
}

@implementation ServerCutTextReader

- (id)initWithProtocol: (RFBProtocol *)aProtocol connection: (RFBConnection *)aConnection;
{
	if (self = [super init]) {
        protocol = aProtocol;
        connection = aConnection;
		dummyReader = [[ByteBlockReader alloc] initTarget:self action:@selector(padding:) size:3];
        textReader = [[RFBStringReader alloc] initTarget:self
                action:@selector(setText:) connection:connection
              encoding:NSISOLatin1StringEncoding];
	}
    return self;
}

- (void)dealloc
{
    [dummyReader release];
    [textReader release];
    [super dealloc];
}

- (void)readMessage
{
    [connection setReader:dummyReader];
}

- (void)padding:(NSData*)pad
{
    CARD32Reader *lengthReader = [[CARD32Reader alloc] initTarget:self action:@selector(setLength:)];
    [connection setReader:lengthReader];
    [lengthReader release];
}

- (void)setLength:(NSNumber *)theLength
{
    unsigned lengthVal = [theLength unsignedIntValue];
    
    if (lengthVal & 0x80000000) {
        // Extended clipboard!
        int32_t slen = (int32_t)lengthVal;
        slen = -slen;
        
        if (slen <= 0 || slen > 1024 * 1024 * 64) { // 64MB limit sanity check
            [protocol messageReaderDone];
            return;
        }
        
        ByteBlockReader *contentReader = [[ByteBlockReader alloc] initTarget:self
                                                                     action:@selector(setExtendedClipboardContent:)
                                                                       size:slen];
        [connection setReader:contentReader];
        [contentReader release];
    } else {
        // Standard CutText
        if (lengthVal == 0) {
            [self setText:@""];
            return;
        }
        ByteBlockReader *contentReader = [[ByteBlockReader alloc] initTarget:self
                                                                     action:@selector(setStandardClipboardContent:)
                                                                       size:lengthVal];
        [connection setReader:contentReader];
        [contentReader release];
    }
}

- (void)setStandardClipboardContent:(NSData *)content
{
    NSString *str = [[NSString alloc] initWithData:content encoding:NSISOLatin1StringEncoding];
    [self setText:str];
    [str release];
}

- (void)setExtendedClipboardContent:(NSData *)content
{
    if ([content length] < 4) {
        [protocol messageReaderDone];
        return;
    }
    
    uint32_t flags;
    [content getBytes:&flags range:NSMakeRange(0, 4)];
    flags = ntohl(flags);
    
    uint32_t action = flags & 0xFF000000;
    
    if (action & 0x01000000) { // clipboardCaps
        [connection setServerSupportsExtendedClipboard:YES];
        [connection setServerClipboardFlags:flags];
        [connection sendClipboardCaps];
        [protocol messageReaderDone];
    }
    else if (action & 0x02000000) { // clipboardRequest
        if (![connection viewOnly]) {
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            NSString *str = [pb stringForType:NSPasteboardTypeString];
            if (str) {
                [connection sendClipboardProvide:str];
            }
        }
        [protocol messageReaderDone];
    }
    else if (action & 0x08000000) { // clipboardNotify
        if (flags & 1) { // clipboardUTF8
            [connection sendClipboardRequest];
        }
        [protocol messageReaderDone];
    }
    else if (action & 0x10000000) { // clipboardProvide
        NSData *compressed = [content subdataWithRange:NSMakeRange(4, [content length] - 4)];
        NSData *decompressed = decompressZlib(compressed);
        if (!decompressed) {
            NSLog(@"Failed to decompress extended clipboard data");
            [protocol messageReaderDone];
            return;
        }
        
        unsigned int offset = 0;
        for (int i = 0; i < 16; i++) {
            if (flags & (1 << i)) {
                if (offset + 4 > [decompressed length]) {
                    break;
                }
                uint32_t itemLen;
                [decompressed getBytes:&itemLen range:NSMakeRange(offset, 4)];
                itemLen = ntohl(itemLen);
                offset += 4;
                
                if (offset + itemLen > [decompressed length]) {
                    break;
                }
                
                if ((1 << i) == 1) { // clipboardUTF8
                    NSData *utf8Data = [decompressed subdataWithRange:NSMakeRange(offset, itemLen)];
                    const char *bytes = [utf8Data bytes];
                    NSUInteger len = [utf8Data length];
                    if (len > 0 && bytes[len - 1] == '\0') {
                        len--;
                    }
                    NSString *str = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
                    if (str) {
                        [self setText:str];
                        [str release];
                        return;
                    }
                }
                offset += itemLen;
            }
        }
        [protocol messageReaderDone];
    }
    else {
        [protocol messageReaderDone];
    }
}

- (void)setText:(NSString*)aText
{
    if (![connection viewOnly]) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];

        [pb declareTypes:[NSArray arrayWithObject:NSPasteboardTypeString] owner:nil];
        [pb setString:aText forType:NSPasteboardTypeString];
    }
    [protocol messageReaderDone];
}

@end
