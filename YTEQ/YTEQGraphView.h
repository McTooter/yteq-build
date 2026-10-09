// YTEQGraphView.h — interactive EQ response graph.
//
// Draws the summed magnitude response of preamp + all bands on a log-frequency axis, with
// one draggable handle per band. Dragging a handle moves that band's frequency (x) and
// gain (y); the handle sits on the curve so it reads as "this is the bump you are moving".
//
// Q is not a 2D axis, so it gets its own column in the panel and is drawn here as the
// shaded -3 dB footprint under each handle.
#import <UIKit/UIKit.h>
#import "YTEQAudioEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class YTEQGraphView;

@protocol YTEQGraphViewDelegate <NSObject>
// Called continuously while dragging so the panel can follow the values live.
- (void)graphView:(YTEQGraphView *)view didChangeBand:(YTEQBand)band atIndex:(NSInteger)index;
- (void)graphView:(YTEQGraphView *)view didSelectBandAtIndex:(NSInteger)index;
@end

@interface YTEQGraphView : UIView

@property (nonatomic, weak, nullable) id<YTEQGraphViewDelegate> delegate;
@property (nonatomic, assign) NSInteger selectedBand;
@property (nonatomic, assign) BOOL editingEnabled;

- (void)refresh; // re-reads parameters from YTEQAudioEngine and redraws

@end

NS_ASSUME_NONNULL_END
