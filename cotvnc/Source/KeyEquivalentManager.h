//
//  KeyEquivalentManager.h
//  Chicken of the VNC
//
//  Created by Jason Harris on Sun Mar 21 2004.
//  Copyright (c) 2004 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class KeyEquivalentScenario;


// Scenarios
extern NSString *kNonConnectionWindowFrontmostScenario;
extern NSString *kConnectionWindowFrontmostScenario;



@interface KeyEquivalentManager : NSObject {
    KeyEquivalentScenario *standardKeyEquivalents;
	NSMutableDictionary *mScenarioDict;		// Scenario -> KeyEquivalentScenario
	NSString *mCurrentScenarioName;
	KeyEquivalentScenario *mCurrentScenario;
	NSView *mKeyRFBView;
}

// Obtaining An Instance
+ (id)defaultManager;

// Persistent Scenarios
- (void)loadScenariosFromPreferences;
- (void)loadScenariosFromDefaults;
- (void)makeScenariosPersistant;
- (void)restoreDefaults;
- (NSDictionary *)propertyList;
- (void)takeScenariosFromPropertyList: (NSDictionary *)propertyList;

// Dealing With The Current Scenario
- (void)setCurrentScenarioToName: (NSString *)scenario;
- (NSString *)currentScenarioName;

// Obtaining Scenario Equivalents
- (KeyEquivalentScenario *)keyEquivalentsForScenarioName: (NSString *)scenario;

// Performing Key Equivalants
- (BOOL)performEquivalentWithCharacters: (NSString *)characters modifiers: (unsigned int)modifiers;

// Obtaining the current RFBView
- (NSView *)keyRFBView;

- (void)removeEquivalentForWindow:(NSString *)title;

@end
