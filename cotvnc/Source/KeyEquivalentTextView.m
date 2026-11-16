//
//  KeyEquivalentTextView.m
//  Chicken of the VNC
//
//  Created by Jason Harris on Thu Apr 08 2004.
//  Copyright (c) 2004 __MyCompanyName__. All rights reserved.
//

#import "KeyEquivalentTextView.h"
#import "KeyEquivalent.h"


@implementation KeyEquivalentTextView

- (KeyEquivalent *)keyEquivalent
{  return mKeyEquivalent;  }


- (void)interpretKeyEvents:(NSArray *)eventArray
{
	NSString *characters = @"";
	unsigned int modifiers = 0;
	NSEnumerator *eventEnumerator = [eventArray objectEnumerator];
	NSEvent *theEvent;
	while (theEvent = [eventEnumerator nextObject])
	{
		characters = [characters stringByAppendingString: [theEvent charactersIgnoringModifiers]];
		modifiers |= [theEvent modifierFlags];
	}
    modifiers |= NSEventModifierFlagCommand;
	modifiers &= 0xFFFF0000;
	mKeyEquivalent = [[KeyEquivalent alloc] initWithCharacters: characters modifiers: modifiers];
	[super interpretKeyEvents: eventArray];
	if ( [characters length] == 1 && [characters characterAtIndex: 0] == 127 )
		[[NSNotificationCenter defaultCenter] postNotificationName: NSTextDidChangeNotification object: self];
}


- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
	NSString *characters = [theEvent charactersIgnoringModifiers];
	NSEventModifierFlags modifiers = [theEvent modifierFlags];
	modifiers &= 0xFFFF0000;
	mKeyEquivalent = [[KeyEquivalent alloc] initWithCharacters: characters modifiers: modifiers];
	[[NSNotificationCenter defaultCenter] postNotificationName: NSTextDidChangeNotification object: self];
	return YES;
}

@end
