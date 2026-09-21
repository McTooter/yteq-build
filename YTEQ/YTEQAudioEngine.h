#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>

NS_ASSUME_NONNULL_BEGIN

// 10 bands: 32,64,125,250,500,1k,2k,4k,8k,16k
#define YTEQ_NUM_BANDS 10

@interface YTEQAudioEngine : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) float preampDB; // -12 .. +12
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bandGains; // 10 x -12..+12

+ (instancetype)shared;
- (void)loadSettings;
- (void)saveSettings;
- (void)resetToFlat;
- (void)applyPreset:(NSString *)name;
- (float)preampLinear;
- (MTAudioProcessingTapRef)createTapWithSampleRate:(double)sampleRate channels:(UInt32)channels;

// realtime DSP, called from tap
- (void)processBuffer:(AudioBufferList *)ioData frames:(UInt32)frames sampleRate:(double)sampleRate channels:(UInt32)channels;

@end

NS_ASSUME_NONNULL_END
