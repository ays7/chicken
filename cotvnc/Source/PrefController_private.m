//
//  PrefController_private.m
//  Chicken of the VNC
//
//  Created by Jason Harris on 8/18/04.
//  Copyright 2004 Geekspiff. All rights reserved.
//

#import "PrefController_private.h"
#import "NSObject_Chicken.h"
#import "ProfileManager.h"


// --- Preference Keys --- //

NSString *kPrefs_UseRendezvous_Key = @"Rendezvous Setting";
NSString *kPrefs_ConnectionProfiles_Key = @"ConnectProfiles";
NSString *kPrefs_FrontFrameBufferUpdateSeconds_Key = @"FrontFrameBufferUpdateSeconds";
NSString *kPrefs_OtherFrameBufferUpdateSeconds_Key = @"OtherFrameBufferUpdateSeconds";
NSString *kPrefs_HostInfo_Key = @"HostPreferences";
NSString *kPrefs_Version_Key = @"Version";
NSString *kPrefs_AutoReconnect_Key = @"AutoReconnect";
NSString *kPrefs_IntervalBeforeReconnect_Key = @"IntervalBeforeReconnect";


// Note: Preference Keys that start with "Listener"
// are defined and used in ListenerController


@implementation PrefController (Private)

#pragma mark Preference Updating


- (void)_updatePrefs_20b2
{
    // No-op (legacy preference migration)
}


#pragma mark -
#pragma mark Preferences Window


- (void)_setupWindow
{
	if ( mWindow )
		return;
	[NSBundle loadNibNamed: @"Preferences" owner: self];
	
	// set our controls' default values
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    
	float updateDelay;
    updateDelay = [defaults floatForKey: kPrefs_FrontFrameBufferUpdateSeconds_Key];
    updateDelay = (float)[mFrontInverseCPUSlider maxValue] - updateDelay;
    [mFrontInverseCPUSlider setFloatValue: updateDelay];
    updateDelay = [defaults floatForKey: kPrefs_OtherFrameBufferUpdateSeconds_Key];
    updateDelay = (float)[mOtherInverseCPUSlider maxValue] - updateDelay;
    [mOtherInverseCPUSlider setFloatValue: updateDelay];

}

@end
