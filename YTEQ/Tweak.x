#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <MediaToolbox/MediaToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import "YTEQAudioEngine.h"
#import "YTEQSettingsViewController.h"

// Universal path: YouTube 19.x uses HAMPlayer (RemoteIO), not AVPlayerItem.
// So we wrap the RemoteIO render callback + keep AVPlayerItem tap as fallback.
// YTEQAudioEngine.h:10 defines YTEQ_NUM_BANDS

static AURenderCallbackStruct g_origCallback = {0, NULL};
static double g_hwSampleRate = 48000.0;

@interface AVPlayerItem (YTEQ)
- (void)yteq_attachTap;
@end

static OSStatus YTEQRenderWrapper(void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus r = noErr;
    if (g_origCallback.inputProc) {
        r = g_origCallback.inputProc(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    } else {
        return noErr;
    }
    if (r == noErr && ioData) {
        @try {
            [[YTEQAudioEngine shared] processBuffer:ioData frames:inNumberFrames sampleRate:g_hwSampleRate channels:ioData->mNumberBuffers];
        } @catch (__unused NSException *e) {}
    }
    return r;
}

%hookf(OSStatus, AudioUnitSetProperty, AudioUnit inUnit, AudioUnitPropertyID inProp, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    // cache HW sample rate
    if (inProp == kAudioUnitProperty_StreamFormat && inData && inDataSize >= sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *fmt = (const AudioStreamBasicDescription *)inData;
        if (fmt->mSampleRate >= 8000 && fmt->mSampleRate <= 192000) {
            g_hwSampleRate = fmt->mSampleRate;
        }
    }
    // wrap render callback (output unit)
    if (inProp == kAudioUnitProperty_SetRenderCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)inData;
        if (cb->inputProc && cb->inputProc != YTEQRenderWrapper) {
            g_origCallback = *cb;
            AURenderCallbackStruct wrapped = {YTEQRenderWrapper, cb->inputProcRefCon};
            return %orig(inUnit, inProp, inScope, inElement, &wrapped, sizeof(wrapped));
        }
    }
    return %orig(inUnit, inProp, inScope, inElement, inData, inDataSize);
}

%hook AVPlayerItem

- (id)initWithURL:(NSURL *)URL {
    id item = %orig;
    if (item) [self yteq_attachTap];
    return item;
}

- (id)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys {
    id item = %orig;
    if (item) [self yteq_attachTap];
    return item;
}

%new
- (void)yteq_attachTap {
    @try {
        AVPlayerItem *item = (AVPlayerItem *)self;
        // Use a mix with tap: create audioMix with one input param + tap
        MTAudioProcessingTapRef tap = [[YTEQAudioEngine shared] createTapWithSampleRate:44100 channels:2];
        if (!tap) return;
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:nil];
        // audioTapProcessor needs MTAudioProcessingTapRef wrapped
        // Use setAudioTapProcessor: via KVC-safe call
        if ([params respondsToSelector:@selector(setAudioTapProcessor:)]) {
            // MTAudioProcessingTapHolder is internal; AVFoundation accepts tap via audioTapProcessor property on iOS 6+
            // Direct assignment:
            [params setValue:(__bridge id)tap forKey:@"audioTapProcessor"];
        }
        mix.inputParameters = @[params];
        item.audioMix = mix;
        CFRelease(tap);
    } @catch (__unused NSException *e) {}
}

// Refresh tap params when engine settings change (no-op, tap reads live)
%end

// Inject EQ button into YouTube settings / account page.
// We hook UIViewController viewDidAppear and add a bar button if class name looks like settings.
// Keeps it generic so it works across YT versions without hard YouTube headers.

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cn = NSStringFromClass([self class]);
    // match YT settings controllers broadly
    if ([cn containsString:@"Settings"] || [cn containsString:@"Account"] || [cn containsString:@"YT"]) {
        if (!self.navigationItem.rightBarButtonItem ||
            self.navigationItem.rightBarButtonItem.tag != 0x594551) {
            UIBarButtonItem *eq = [[UIBarButtonItem alloc] initWithTitle:@"EQ"
                style:UIBarButtonItemStylePlain target:self action:@selector(yteq_openEQ)];
            eq.tag = 0x594551; // 'YEQ'
            // preserve existing left items, just add EQ on right if free
            if (!self.navigationItem.rightBarButtonItem) {
                self.navigationItem.rightBarButtonItem = eq;
            }
        }
    }
}

%new
- (void)yteq_openEQ {
    YTEQSettingsViewController *vc = [[YTEQSettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

%end

%ctor {
    [[YTEQAudioEngine shared] loadSettings];
}
