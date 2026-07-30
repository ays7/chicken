//
//  TouchBarController.h
//  Chicken of the VNC
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const cotvncTouchBarNeedsUpdateNotification;

@interface TouchBarController : NSObject <NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate>

+ (TouchBarController *)sharedController;

- (NSTouchBar *)makeTouchBar;
- (void)updateTouchBar;

@end

NS_ASSUME_NONNULL_END
