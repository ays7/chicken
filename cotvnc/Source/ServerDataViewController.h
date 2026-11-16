//
//  ServerDataViewController.h
//  Chicken of the VNC
//
//  Created by Jared McIntyre on Sun May 1 2004.
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
//


#import <Cocoa/Cocoa.h>
#import "ConnectionWaiter.h"

@protocol IServerData;
@protocol ConnectionDelegate;
@class RFBConnection;
@class RFBConnectionManager;
@class ServerBase;

@interface ServerDataViewController : NSWindowController
                                            <ConnectionWaiterDelegate, NSControlTextEditingDelegate>
{
    IBOutlet __weak NSSegmentedControl *protocolControl;
    IBOutlet __weak NSTextField *protocolLabel;
    IBOutlet __weak NSTextField *displayLabel;
    IBOutlet __weak NSTextField *display;
    IBOutlet __weak NSTextField *displayDescription;
    IBOutlet __weak NSTextField *hostName;
    IBOutlet __weak NSTextField *username;
    IBOutlet __weak NSTextField *usernameLabel;
    IBOutlet __weak NSTextField *password;
    IBOutlet __weak NSTextField *passwordLabel;
    IBOutlet __weak NSPopUpButton *profilePopup;
    IBOutlet __weak NSTextField *profileLabel;
    IBOutlet __weak NSButton *rememberPwd;

    IBOutlet __weak NSButton *shared;
	IBOutlet __weak NSButton *viewOnly;
	IBOutlet __weak NSButton *fullscreen;
	IBOutlet __weak NSButton *useAllScreens;
	IBOutlet NSButton *save;
    IBOutlet __weak NSButton *useSshTunnel;
    IBOutlet __weak NSTextField *sshHost;
    IBOutlet __weak NSTextField *sshHostLabel;

	IBOutlet __weak NSBox *box;
	IBOutlet __weak NSButton *connectBtn;
	
	IBOutlet __weak NSProgressIndicator *connectIndicator;
	IBOutlet __weak NSTextField *connectIndicatorText;
	
	ServerBase  *mServer;
	
	bool selfTerminate;
	bool removedSaveCheckbox;

    ConnectionWaiter    *connectionWaiter;
    BOOL saveCheckboxWasVisible;
    NSArray             *topLevelObjects;
    __weak RFBConnectionManager *superController;
}

- (id)initWithReleaseOnCloseOrConnect;

- (void)setServer:(id<IServerData>)server;
- (id<IServerData>)server;

- (IBAction)protocolChanged:(id)sender;
- (IBAction)usernameChanged:(id)sender;
- (IBAction)passwordChanged:(id)sender;
- (IBAction)rememberPwdChanged:(id)sender;
- (IBAction)profileSelectionChanged:(id)sender;

- (IBAction)sharedChanged:(id)sender;
- (IBAction)viewOnlyChanged:(id)sender;
- (IBAction)fullscreenChanged:(id)sender;
- (IBAction)useAllScreensChanged:(id)sender;
- (IBAction)useSshTunnelChanged:(id)sender;
- (IBAction)sshHostChanged:(id)sender;
- (IBAction)connectToServer:(id)sender;
- (IBAction)addServerChanged:(id)sender;

- (IBAction)showProfileManager:(id)sender;

- (IBAction)cancelConnect: (id)sender;

- (void)connectionSucceeded: (id<RemoteConnection>)theConnection;
- (void)connectionFailed;
- (void)connectionAttemptEnded;

- (void)disableControls;

- (NSBox*)box;

- (void)updateView:(id)notification;
- (void)updateProfileView:(id)notification;
- (void)setProfilePopupToProfile: (Profile *)profileName;

- (void)loadProfileIntoView;

- (void)setSaveCheckboxIsVisible:(BOOL)visible;
- (void)setSuperController:(RFBConnectionManager *)aSuperController;

@end
