// YTEQAudioHook.h — installs the DSP into the app's audio path.
//
// Follows the strategy of VolumeBoostYT.dylib: no Substrate/ElleKit. That tweak works by
// swizzling AVFoundation's -setVolume: on AVPlayer / AVAudioPlayer / AVAudioPlayerNode /
// AVSampleBufferAudioRenderer, so it runs in a bare dylib injected by Sideloadly.
//
// VolumeBoostYT only multiplies a scalar volume, which needs no sample access. An EQ has to
// touch every sample, so the hook here wraps the RemoteIO render callback
// (AudioUnitSetProperty + kAudioUnitProperty_SetRenderCallback) to get an AudioBufferList.
// That is the same render callback the old tweak's predecessor used, and it is the point
// where YouTube's decoded audio is on its way to the speaker.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTEQAudioHook : NSObject

// Idempotent. Call once from the tweak constructor.
+ (void)install;

// Diagnostics for the settings screen, so the user can tell whether audio is reaching us.
@property (class, nonatomic, readonly) BOOL renderCallbackInstalled;
@property (class, nonatomic, readonly) BOOL hasSeenAudio;
@property (class, nonatomic, readonly) double observedSampleRate;
@property (class, nonatomic, readonly) int observedChannels;

@end

NS_ASSUME_NONNULL_END
