//
//  TouchBarController.h
//  Chicken of the VNC
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class Session;

extern NSString * const cotvncTouchBarNeedsUpdateNotification;

@interface TouchBarController : NSObject <NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate>

+ (TouchBarController *)sharedController;

- (NSTouchBar *)makeTouchBar;
- (void)updateTouchBar;
- (nullable Session *)activeSessionForServerName:(NSString *)serverName;

@end

NS_ASSUME_NONNULL_END
