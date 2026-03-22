//
//  KeyEquivalent.h
//  Chicken of the VNC
//
//  Created by Jason Harris on Sun Mar 21 2004.
//  Copyright (c) 2004 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

/* Encapsulates key press with modifiers. This is mapped to a menu event by
 * KeyEquivalentScenario. */
@interface KeyEquivalent : NSObject <NSCopying> {
	NSString *mCharacters;
    NSEventModifierFlags mModifiers;
}

- (id)initWithCharacters: (NSString *)characters modifiers: (NSEventModifierFlags)modifiers;
- (BOOL)isEqualToKeyEquivalent: (KeyEquivalent *)anObject;
- (NSString *)characters;
- (NSEventModifierFlags)modifiers;
- (NSAttributedString *)userString;
- (NSString *)string;

@end

