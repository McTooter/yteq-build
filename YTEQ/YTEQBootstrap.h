// YTEQBootstrap.h — installs the tweak and puts a way to reach the panel inside YouTube.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTEQBootstrap : NSObject

// Runs from the image constructor. Safe to call more than once.
+ (void)install;

@end

NS_ASSUME_NONNULL_END
