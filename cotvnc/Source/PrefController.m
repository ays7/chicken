//
//  PrefController.m
//  Chicken of the VNC
//
//  Created by Jason Harris on 8/18/04.
//  Copyright 2004 Geekspiff. All rights reserved.
//

#import "PrefController.h"
#import "PrefController_private.h"
#import "ProfileManager.h"
#import "RFBConnectionManager.h"

// Obsolete framebuffer imports removed


// --- Preferences Version --- //
static int const kPrefsVersion = 0x00000002;


@implementation PrefController

#pragma mark Creation and Deletion


+ (void)initialize
{
	NSUserDefaults *defaults;
	NSMutableDictionary *defaultDict;
	NSDictionary *profiles;
	
	defaults = [NSUserDefaults standardUserDefaults];
	defaultDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithBool: YES],			kPrefs_UseRendezvous_Key,
		[NSNumber numberWithFloat: 0],			kPrefs_FrontFrameBufferUpdateSeconds_Key,
		[NSNumber numberWithFloat: 0.9],		kPrefs_OtherFrameBufferUpdateSeconds_Key, 
		[NSNumber numberWithBool: YES],			kPrefs_AutoReconnect_Key, 
		[NSNumber numberWithDouble: 30.0],		kPrefs_IntervalBeforeReconnect_Key, 
		nil,									nil];
	
    Profile *defaultProfile = [[Profile alloc] init];
	NSString *profileName = NSLocalizedString(@"defaultProfileName", nil);
    profiles = [NSDictionary dictionaryWithObject: [defaultProfile dictionary]
                                           forKey:profileName];
    [defaultDict setObject: profiles forKey: kPrefs_ConnectionProfiles_Key];
    [defaultProfile release];
	
	[defaults registerDefaults: defaultDict];
}


+ (id)sharedController
{
	static id sInstance = nil;
	if ( ! sInstance )
	{
		sInstance = [[self alloc] init];
		NSParameterAssert( sInstance != nil );
	}
	return sInstance;
}


- (id)init
{
	if ( self = [super init] )
	{
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		int prefsVersion = [[defaults objectForKey: kPrefs_Version_Key] intValue];
		BOOL badPrefsVersion = (kPrefsVersion > prefsVersion);
		if ( 0x00000000 == prefsVersion )
		{
			// update for 2.0b2
			[self _updatePrefs_20b2];
			prefsVersion = 0x00000001;
		}
		if ( 0x00000001 == prefsVersion )
		{
			// some menu items have changed
			[defaults removeObjectForKey: @"KeyEquivalentScenarios"];
			prefsVersion = 0x00000002;
		}
		
		if ( badPrefsVersion )
			[defaults setObject: [NSNumber numberWithInt: kPrefsVersion] forKey: kPrefs_Version_Key];
	}
	return self;
}


#pragma mark -
#pragma mark Settings





- (float)frontFrameBufferUpdateSeconds
{  return [[[NSUserDefaults standardUserDefaults] objectForKey: kPrefs_FrontFrameBufferUpdateSeconds_Key] floatValue];  }


- (float)otherFrameBufferUpdateSeconds
{  return [[[NSUserDefaults standardUserDefaults] objectForKey: kPrefs_OtherFrameBufferUpdateSeconds_Key] floatValue];  }


- (float)gammaCorrection
{
	return 1.1;
}

- (float)maxPossibleFrameBufferUpdateSeconds;
{
	// this is a bit ugly - our window might not be loaded yet, so if it's not, hardcode the value, yick
	if ( mWindow )
		return [mFrontInverseCPUSlider maxValue];
	return 1;
}


- (BOOL)usesRendezvous
{  return [[NSUserDefaults standardUserDefaults] boolForKey: kPrefs_UseRendezvous_Key];  }


- (NSDictionary *)hostInfo
{  return [[NSUserDefaults standardUserDefaults] objectForKey: kPrefs_HostInfo_Key];  }


- (void)setHostInfo: (NSDictionary *)dict
{  [[NSUserDefaults standardUserDefaults] setObject: dict forKey: kPrefs_HostInfo_Key];  }


- (NSDictionary *)profileDict
{  return [[NSUserDefaults standardUserDefaults] objectForKey: kPrefs_ConnectionProfiles_Key];  }


- (NSDictionary *)defaultProfileDict
{
	return [[[[[NSUserDefaults standardUserDefaults] volatileDomainForName: NSRegistrationDomain] objectForKey: kPrefs_ConnectionProfiles_Key] allValues] lastObject];
}


- (void)setProfileDict: (NSDictionary *)dict
{  [[NSUserDefaults standardUserDefaults] setObject: dict forKey: kPrefs_ConnectionProfiles_Key];  }


- (BOOL)autoReconnect
{  return [[NSUserDefaults standardUserDefaults] boolForKey: kPrefs_AutoReconnect_Key];  }


- (NSTimeInterval)intervalBeforeReconnect
{  return [[NSUserDefaults standardUserDefaults] floatForKey: kPrefs_IntervalBeforeReconnect_Key];  }


#pragma mark -
#pragma mark Preferences Window


- (void)showWindow
{
	[self _setupWindow];
	[mWindow makeKeyAndOrderFront: nil];
}


#pragma mark -
#pragma mark Action Methods


- (IBAction)frontInverseCPUSliderChanged: (NSSlider *)sender
{
	float updateDelay = [sender floatValue];
	updateDelay = (float)[sender maxValue] - updateDelay;
	[[NSUserDefaults standardUserDefaults] setFloat: updateDelay forKey: kPrefs_FrontFrameBufferUpdateSeconds_Key];
	[[RFBConnectionManager sharedManager] setFrontWindowUpdateInterval: updateDelay];
}

- (IBAction)otherInverseCPUSliderChanged: (NSSlider *)sender
{
	float updateDelay = [sender floatValue];
	updateDelay = (float)[sender maxValue] - updateDelay;
	[[NSUserDefaults standardUserDefaults] setFloat: updateDelay forKey: kPrefs_OtherFrameBufferUpdateSeconds_Key];
	[[RFBConnectionManager sharedManager] setOtherWindowUpdateInterval: updateDelay];
}





- (IBAction)toggleUseRendezvous: (id)sender
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	BOOL use = ! [[defaults objectForKey: kPrefs_UseRendezvous_Key] boolValue];
	[defaults setBool: use forKey: kPrefs_UseRendezvous_Key];

	[[RFBConnectionManager sharedManager] useRendezvous: use];
}

@end
