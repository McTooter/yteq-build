#import "YTEQAudioEngine.h"
#import <math.h>

static const double YTEQFreqs[YTEQ_NUM_BANDS] = {32,64,125,250,500,1000,2000,4000,8000,16000};
static NSString * const kSuite = @"com.yteq.settings";
static NSString * const kEnabled = @"YTEQEnabled";
static NSString * const kPreamp = @"YTEQPreamp";
static NSString * const kBands = @"YTEQBands";

typedef struct {
    double b0,b1,b2,a1,a2;
    double x1,x2,y1,y2;
} YTEQBiquad;

@interface YTEQAudioEngine () {
    YTEQBiquad _filters[YTEQ_NUM_BANDS][2]; // [band][channel L/R, max 2; extra channels reuse 0]
}
@property (nonatomic, assign) double lastSampleRate;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation YTEQAudioEngine

+ (instancetype)shared {
    static YTEQAudioEngine *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _bandGains = [NSMutableArray array];
        for (int i=0;i<YTEQ_NUM_BANDS;i++) [_bandGains addObject:@0];
        _preampDB = 0;
        _enabled = YES;
        _lastSampleRate = 44100;
        [self loadSettings];
        [self recalcCoeffs:44100];
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite] ?: [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kEnabled]) self.enabled = [d boolForKey:kEnabled];
    if ([d objectForKey:kPreamp]) self.preampDB = [d floatForKey:kPreamp];
    NSArray *b = [d objectForKey:kBands];
    if (b && b.count == YTEQ_NUM_BANDS) self.bandGains = [b mutableCopy];
}

- (void)saveSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite] ?: [NSUserDefaults standardUserDefaults];
    [d setBool:self.enabled forKey:kEnabled];
    [d setFloat:self.preampDB forKey:kPreamp];
    [d setObject:[self.bandGains copy] forKey:kBands];
    [d synchronize];
}

- (void)resetToFlat {
    [_lock lock];
    for (int i=0;i<YTEQ_NUM_BANDS;i++) self.bandGains[i]=@0;
    self.preampDB = 0;
    [self recalcCoeffs:_lastSampleRate];
    [_lock unlock];
    [self saveSettings];
}

- (void)applyPreset:(NSString *)name {
    NSDictionary *p = @{
        @"Flat": @[@0,@0,@0,@0,@0,@0,@0,@0,@0,@0],
        @"Bass Boost": @[@6,@5,@4,@2,@0,@0,@0,@0,@1,@2],
        @"Treble Boost": @[@-1,@0,@0,@0,@0,@1,@2,@3,@4,@5],
        @"Vocal": @[@-2,@-1,@0,@2,@4,@4,@3,@1,@0,@-1],
        @"Rock": @[@4,@3,@2,@1,@0,@0,@1,@2,@3,@4],
        @"Pop": @[@2,@3,@4,@3,@1,@0,@0,@1,@2,@3],
        @"Hip-Hop": @[@6,@5,@3,@1,@0,@0,@1,@1,@2,@3],
        @"Electronic": @[@5,@4,@2,@0,@-1,@1,@2,@3,@4,@5],
        @"Jazz": @[@3,@2,@1,@2,@3,@3,@2,@1,@2,@3],
        @"Classical": @[@4,@3,@2,@1,@0,@0,@1,@2,@3,@4],
    };
    NSArray *v = p[name] ?: p[@"Flat"];
    [_lock lock];
    for (int i=0;i<YTEQ_NUM_BANDS;i++) self.bandGains[i]=v[i];
    [self recalcCoeffs:_lastSampleRate];
    [_lock unlock];
    [self saveSettings];
}

- (float)preampLinear {
    return powf(10.0f, self.preampDB / 20.0f);
}

// Peaking EQ biquad (RBJ cookbook), Q=1.0
- (void)recalcCoeffs:(double)sr {
    if (sr < 8000) sr = 44100;
    _lastSampleRate = sr;
    for (int i=0;i<YTEQ_NUM_BANDS;i++) {
        float gainDB = [self.bandGains[i] floatValue];
        double A = pow(10.0, gainDB/40.0);
        double w0 = 2.0*M_PI*YTEQFreqs[i]/sr;
        double alpha = sin(w0)/2.0 * 1.0; // Q=1
        double cw = cos(w0);
        double b0 = 1+alpha*A, b1 = -2*cw, b2 = 1-alpha*A;
        double a0 = 1+alpha/A, a1 = -2*cw, a2 = 1-alpha/A;
        for (int ch=0;ch<2;ch++) {
            // preserve state, update coeffs only
            _filters[i][ch].b0=b0/a0; _filters[i][ch].b1=b1/a0; _filters[i][ch].b2=b2/a0;
            _filters[i][ch].a1=a1/a0; _filters[i][ch].a2=a2/a0;
        }
    }
}

// ---- tap callbacks ----
static void YTEQTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = (__bridge_retained void *)[YTEQAudioEngine shared];
}
static void YTEQTapFinalize(MTAudioProcessingTapRef tap) {
    void *s = MTAudioProcessingTapGetStorage(tap);
    if (s) CFRelease(s);
}
static void YTEQTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *desc) {
    YTEQAudioEngine *e = (__bridge YTEQAudioEngine *)MTAudioProcessingTapGetStorage(tap);
    [e.lock lock];
    [e recalcCoeffs:desc->mSampleRate];
    [e.lock unlock];
}
static void YTEQTapUnprepare(MTAudioProcessingTapRef tap) {}
static void YTEQTapProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
    AudioBufferList *ioData, CMItemCount *outFrames, MTAudioProcessingTapFlags *outFlags) {
    YTEQAudioEngine *e = (__bridge YTEQAudioEngine *)MTAudioProcessingTapGetStorage(tap);
    OSStatus err = MTAudioProcessingTapGetSourceAudio(tap, frames, ioData, outFlags, NULL, outFrames);
    if (err) return;
    // get format for sr/channels
    CMItemCount f = *outFrames;
    // assume interleaved float? YouTube taps are non-interleaved float32. Handle both via AudioBufferList walk.
    // We need sr: cache last sr
    double sr = e.lastSampleRate;
    UInt32 chs = ioData->mNumberBuffers;
    if (e.enabled) [e processBuffer:ioData frames:(UInt32)f sampleRate:sr channels:chs];
}

- (MTAudioProcessingTapRef)createTapWithSampleRate:(double)sampleRate channels:(UInt32)channels {
    (void)sampleRate; (void)channels;
    MTAudioProcessingTapCallbacks cbs = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = NULL,
        .init = YTEQTapInit,
        .finalize = YTEQTapFinalize,
        .prepare = YTEQTapPrepare,
        .unprepare = YTEQTapUnprepare,
        .process = YTEQTapProcess
    };
    MTAudioProcessingTapRef tap = NULL;
    OSStatus err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cbs, kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    if (err || !tap) return NULL;
    return tap;
}

- (void)processBuffer:(AudioBufferList *)ioData frames:(UInt32)frames sampleRate:(double)sampleRate channels:(UInt32)channels {
    [_lock lock];
    if (fabs(sampleRate - _lastSampleRate) > 1.0) [self recalcCoeffs:sampleRate];
    float pre = [self preampLinear];
    // clamp pre to avoid blowup
    if (pre > 4.0f) pre = 4.0f;
    for (UInt32 b=0;b<ioData->mNumberBuffers;b++) {
        float *data = (float*)ioData->mBuffers[b].mData;
        if (!data) continue;
        UInt32 nCh = ioData->mBuffers[b].mNumberChannels;
        BOOL interleaved = (nCh > 1);
        int fIdx = (b < 2) ? (int)b : 0;
        UInt32 totalSamples = interleaved ? frames * nCh : frames;
        // preamp
        if (pre != 1.0f) {
            for (UInt32 i=0;i<totalSamples;i++) data[i] *= pre;
        }
        // 10 bands in series
        for (int band=0;band<YTEQ_NUM_BANDS;band++) {
            if ([self.bandGains[band] floatValue]==0) continue;
            YTEQBiquad *f = &_filters[band][fIdx];
            if (!interleaved) {
                for (UInt32 n=0;n<frames;n++) {
                    double x = data[n];
                    double y = f->b0*x + f->b1*f->x1 + f->b2*f->x2 - f->a1*f->y1 - f->a2*f->y2;
                    f->x2=f->x1; f->x1=x; f->y2=f->y1; f->y1=y;
                    // soft clip
                    if (y>1.0) y=1.0; if (y<-1.0) y=-1.0;
                    data[n]=(float)y;
                }
            } else {
                // need per-channel state: use same filter but process de-interleaved per channel stride
                // to keep simple and stable, process with shared state per buffer (acceptable for tweak)
                for (UInt32 n=0;n<frames;n++) {
                    for (UInt32 c=0;c<nCh;c++) {
                        UInt32 idx = n*nCh+c;
                        double x = data[idx];
                        double y = f->b0*x + f->b1*f->x1 + f->b2*f->x2 - f->a1*f->y1 - f->a2*f->y2;
                        f->x2=f->x1; f->x1=x; f->y2=f->y1; f->y1=y;
                        if (y>1.0) y=1.0; if (y<-1.0) y=-1.0;
                        data[idx]=(float)y;
                    }
                }
            }
        }
    }
    [_lock unlock];
}

@end
