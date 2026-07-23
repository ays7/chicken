//
//  KeyEquivalentManager.m
//  Chicken of the VNC
//
//  Created by Jason Harris on Sun Mar 21 2004.
//  Copyright (c) 2004 __MyCompanyName__. All rights reserved.
//

#import "KeyEquivalentManager.h"
#import "AppDelegate.h"
#import "KeyEquivalent.h"
#import "KeyEquivalentEntry.h"
#import "KeyEquivalentPrefsController.h"
#import "KeyEquivalentScenario.h"
#import "Session.h"


// Scenarios
NSString *kNonConnectionWindowFrontmostScenario = @"NonConnectionWindowFrontmostScenario";
NSString *kConnectionWindowFrontmostScenario = @"ConnectionWindowFrontmostScenario";


@interface KeyEquivalentManager(Private)

- (void)loadScenarios;

@end


@implementation KeyEquivalentManager

#pragma mark -
#pragma mark Private


- (void)makeAllScenariosInactive
{
	NSEnumerator *scenarioEnumerator = [mScenarioDict keyEnumerator];
	NSString *scenarioName;
	
	while ( scenarioName = [scenarioEnumerator nextObject] )
	{
		KeyEquivalentScenario *scenario = [mScenarioDict objectForKey: scenarioName];
		[scenario makeActive: NO];
	}
}


- (void)rfbViewDidBecomeKey: (NSView *)view
{
	mKeyRFBView = view;
	Session *session = nil;
	if ([view respondsToSelector:@selector(connection)]) {
		id conn = [view performSelector:@selector(connection)];
		if (conn && [conn respondsToSelector:@selector(delegate)]) {
			id delegate = [conn performSelector:@selector(delegate)];
			if (delegate && [delegate respondsToSelector:@selector(session)]) {
				session = [delegate performSelector:@selector(session)];
			}
		}
	}
	if (session)
	{
        if ([session viewOnly])
            [self setCurrentScenarioToName: kNonConnectionWindowFrontmostScenario];
		else
			[self setCurrentScenarioToName: kConnectionWindowFrontmostScenario];
	}
}


- (void)windowDidBecomeKey:(NSNotification *)aNotification
{
	Class VNCViewClass = NSClassFromString(@"VNCCAFramebufferView");
	Class NSScrollViewClass = [NSScrollView class];
	
	NSWindow *window = [aNotification object];
    if ([[window className] isEqualToString: @"NSCarbonMenuWindow"]) {
        return;
    }

	NSView *contentView = [window contentView];
	if ( [contentView isKindOfClass: NSScrollViewClass] )
		contentView = [(NSScrollView *)contentView documentView];
	if ( VNCViewClass && [contentView isKindOfClass: VNCViewClass] )
	{
		[self rfbViewDidBecomeKey: (NSView *)contentView];
 		return;
	}
	
	NSEnumerator *subviewEnumerator = [[contentView subviews] objectEnumerator];
	NSView *subview;
	
	while ( subview = [subviewEnumerator nextObject] )
	{
		if ( [subview isKindOfClass: NSScrollViewClass] )
			subview = [(NSScrollView *)subview documentView];
		if ( VNCViewClass && [subview isKindOfClass: VNCViewClass] )
		{
			[self rfbViewDidBecomeKey: (NSView *)subview];
			return;
		}
	}
	mKeyRFBView = nil;
	if (window)
		[self setCurrentScenarioToName: kNonConnectionWindowFrontmostScenario];
}


- (void)windowWillClose:(NSNotification *)aNotification
{
	NSWindow *closingWindow = [aNotification object];

    // remove window from KeyEquivalentScenarios if necessary
    [self removeEquivalentForWindow:[closingWindow title]];

    // if all windows now closed, go to non-connection window scenario
	NSEnumerator *windowEnumerator = [[NSApp windows] objectEnumerator];
	NSWindow *window;
	while ( window = [windowEnumerator nextObject] )
    {
		if ( window != closingWindow && [window isVisible] )
        {
			return;
        }
	}
	[self setCurrentScenarioToName: kNonConnectionWindowFrontmostScenario];
}


- (NSString *)description
{  return [mScenarioDict description];  }


#pragma mark -
#pragma mark Obtaining An Instance

+ (id)defaultManager
{
	static id sDefaultManager = nil;
	
	if ( ! sDefaultManager )
	{
		sDefaultManager = [[self alloc] init];
		NSParameterAssert( sDefaultManager != nil );
	}
	return sDefaultManager;
}


- (id)init
{
	if ( self = [super init] )
	{
        /* Get the unaltered key equivalents, which form the basis for our
         * defaults. */
        standardKeyEquivalents = [[KeyEquivalentScenario alloc] initFromMainMenu];
        [self loadScenarios];

		NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
		[notificationCenter addObserver: self selector: @selector(windowDidBecomeKey:) name: NSWindowDidBecomeKeyNotification object: nil];
		[notificationCenter addObserver: self selector: @selector(windowWillClose:) name: NSWindowWillCloseNotification object: nil];
	}
	return self;
}


- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[mScenarioDict release];
	[mCurrentScenarioName release];
	[super dealloc];
}


#pragma mark -
#pragma mark Persistent Scenarios


- (void)loadScenarios
{
	[self loadScenariosFromPreferences];
	if ( ! mScenarioDict || [mScenarioDict count] == 0 )
		[self loadScenariosFromDefaults];
	NSParameterAssert( mScenarioDict && [mScenarioDict count] > 0 );
}


- (void)loadScenariosFromPreferences
{
	NSUserDefaults *defaults;
	NSDictionary *foundDict;
	
	defaults = [NSUserDefaults standardUserDefaults];
	[defaults synchronize];
	foundDict = [defaults objectForKey: @"KeyEquivalentScenarios"];
	if ( foundDict )
		[self takeScenariosFromPropertyList: foundDict];
}


/* Load default settings for key equivalent scenarios. */
- (void)loadScenariosFromDefaults
{
    KeyEquivalentScenario   *minimal;
    
    minimal = [[KeyEquivalentScenario alloc] init];

    [mScenarioDict release];
    mScenarioDict = [[NSMutableDictionary alloc] init];
    [mScenarioDict setObject:[[standardKeyEquivalents copy] autorelease]
                      forKey:kNonConnectionWindowFrontmostScenario];
    [mScenarioDict setObject:minimal forKey:kConnectionWindowFrontmostScenario];

    [minimal release];
}


- (void)makeScenariosPersistant
{
	NSUserDefaults *defaults;
	
	defaults = [NSUserDefaults standardUserDefaults];
	[defaults setObject: [self propertyList] forKey: @"KeyEquivalentScenarios"];
}


- (void)restoreDefaults
{
	NSUserDefaults *defaults;
	
	defaults = [NSUserDefaults standardUserDefaults];
	[defaults removeObjectForKey: @"KeyEquivalentScenarios"];
	[self loadScenariosFromDefaults];
}


- (NSDictionary *)propertyList
{
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	NSEnumerator *scenarioNameEnumerator = [mScenarioDict keyEnumerator];
	NSString *scenarioName;
	
	while ( scenarioName = [scenarioNameEnumerator nextObject] )
	{
		NSArray *scenarioArray = [[mScenarioDict objectForKey: scenarioName] propertyList];
		[dict setObject: scenarioArray forKey: scenarioName];
	}
	return dict;
}


- (void)takeScenariosFromPropertyList: (NSDictionary *)propertyList
{
	if ( ! mScenarioDict )
		mScenarioDict = [[NSMutableDictionary alloc] init];
	NSEnumerator *scenarioNameEnumerator = [propertyList keyEnumerator];
	NSString *scenarioName;
	while ( scenarioName = [scenarioNameEnumerator nextObject] )
	{
		KeyEquivalentScenario *scenario = [[KeyEquivalentScenario alloc] initWithPropertyList: [propertyList objectForKey: scenarioName]];
		[mScenarioDict setObject: scenario forKey: scenarioName];
		[scenario release];
	}
}


#pragma mark -
#pragma mark Dealing With The Current Scenario


- (void)setCurrentScenarioToName: (NSString *)scenario
{
	if (scenario == mCurrentScenarioName)
		return;
	mCurrentScenario = [mScenarioDict objectForKey: scenario];
	[self makeAllScenariosInactive];
	[mCurrentScenario makeActive: YES];
	[mCurrentScenarioName release];
	mCurrentScenarioName = [scenario retain];
}


- (NSString *)currentScenarioName
{  return mCurrentScenarioName;  }


#pragma mark -
#pragma mark Obtaining Scenario Equivalents


- (KeyEquivalentScenario *)keyEquivalentsForScenarioName: (NSString *)scenario
{  return [mScenarioDict objectForKey: scenario];  }


#pragma mark -
#pragma mark Performing Key Equivalants


- (BOOL)performEquivalentWithCharacters: (NSString *)characters modifiers: (unsigned int)modifiers
{
	KeyEquivalent *keyEquivalent = [[KeyEquivalent alloc] initWithCharacters: characters modifiers: modifiers];
	NSMenuItem *menuItem = [mCurrentScenario menuItemForKeyEquivalent: keyEquivalent];
	[keyEquivalent release];
	if ( menuItem )
	{
		[NSApp sendAction: [menuItem action] to: [menuItem target] from: menuItem];
		return YES;
	}
	return NO;
}


#pragma mark -
#pragma mark Performing Key Equivalants


- (NSView *)keyRFBView
{  return mKeyRFBView;  }


- (void)removeEquivalentForWindow:(NSString *)title
{
    KeyEquivalentEntry      *entry;
    NSEnumerator            *e = [mScenarioDict objectEnumerator];
    KeyEquivalentScenario   *scen;
    
    entry = [[KeyEquivalentEntry alloc] initWithTitle: title];
    while (scen = [e nextObject])
        [scen removeEntry: entry];
    [entry release];
    [[KeyEquivalentPrefsController sharedController] menusChanged];
}

@end
