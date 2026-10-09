// YTEQPanelViewController.h — the EQ control surface.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTEQPanelViewController : UIViewController

// Presents modally, wrapped in a navigation controller with a Done button.
+ (void)presentFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
