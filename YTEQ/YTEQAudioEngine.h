// YTEQAudioEngine.h — EQ settings, coefficient design and realtime DSP.
//
// The engine is a pure C DSP core with a thin Objective-C shell for persistence, so the
// audio callback path (YTEQAudioEngineProcess) is lock-free and allocation-free.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// 10 parametric bands. Centre frequencies are user-movable, so this is a parametric EQ
// rather than a fixed graphic EQ.
#define YTEQ_NUM_BANDS 10

// Default centres, spanning two octaves either side of the classic graphic-EQ layout.
#define YTEQ_DEFAULT_FREQ(i) \
    ((i) == 0 ? 31.5 : (i) == 1 ? 63 : (i) == 2 ? 125 : (i) == 3 ? 250 : \
     (i) == 4 ? 500 : (i) == 5 ? 1000 : (i) == 6 ? 2000 : (i) == 7 ? 4000 : \
     (i) == 8 ? 8000 : 16000)

// Filter shapes a band can take.
typedef NS_ENUM(NSInteger, YTEQFilterType) {
    YTEQFilterTypeParametric = 0, // peaking
    YTEQFilterTypeLowShelf,
    YTEQFilterTypeHighShelf,
    YTEQFilterTypeLowPass,
    YTEQFilterTypeHighPass,
    YTEQFilterTypeBandPass,
    YTEQFilterTypeNotch,
};

// Per-band parameters. Mirrors what the UI edits.
typedef struct {
    double freq;   // Hz, clamped to [YTEQ_MIN_FREQ, YTEQ_MAX_FREQ]
    double gainDB; // dB, clamped to [YTEQ_MIN_GAIN, YTEQ_MAX_GAIN]
    double q;      // dimensionless, clamped to [YTEQ_MIN_Q, YTEQ_MAX_Q]
    int    type;   // YTEQFilterType
    BOOL   enabled;
} YTEQBand;

// One Direct-Form-I biquad with per-channel state.
#define YTEQ_MAX_CHANNELS 8

typedef struct {
    double b0, b1, b2, a1, a2;
} YTEQCoeffs;

typedef struct {
    YTEQCoeffs c;
    double x1, x2, y1, y2;
} YTEQStage;

// A full EQ instance: coefficients plus per-channel filter memory.
typedef struct {
    YTEQStage stage[YTEQ_NUM_BANDS][YTEQ_MAX_CHANNELS];
    uint32_t  activeMask;   // bit N set when band N is not an identity filter
    double    preampLin;    // linear gain applied before the cascade
    double    sampleRate;
    int       channelCount;
    BOOL      enabled;
} YTEQState;

// ---- parameter limits (shared with the UI) ----
#define YTEQ_MIN_FREQ     20.0
#define YTEQ_MAX_FREQ     20000.0
#define YTEQ_MIN_GAIN     (-15.0)
#define YTEQ_MAX_GAIN     15.0
#define YTEQ_MIN_Q        0.1
#define YTEQ_MAX_Q        12.0
#define YTEQ_MIN_PREAMP   (-15.0)
#define YTEQ_MAX_PREAMP   15.0

#ifdef __cplusplus
extern "C" {
#endif

// Design a single biquad (RBJ audio-EQ-cookbook) for the given parameters.
FOUNDATION_EXPORT void YTEQDesignCoeffs(YTEQCoeffs *out, YTEQFilterType type,
                                        double sampleRate, double freq,
                                        double gainDB, double q);

// Design all bands + preamp into `state` and reset filter memory.
// `channelCount` is clamped to [1, YTEQ_MAX_CHANNELS].
FOUNDATION_EXPORT void YTEQStateConfigure(YTEQState *state, const YTEQBand *bands,
                                          double preampDB, double sampleRate,
                                          int channelCount, BOOL enabled);

// Update only the coefficients, leaving filter memory (x1/x2/y1/y2) intact.
// This is what interactive sliders use: re-zeroing the state on every drag tick would
// restart each band from rest, which audibly retriggers every filter.
FOUNDATION_EXPORT void YTEQStateUpdateCoefficients(YTEQState *state, const YTEQBand *bands,
                                                   double preampDB, BOOL enabled);

// Clear all filter memory (call on stream start to avoid a click).
FOUNDATION_EXPORT void YTEQStateReset(YTEQState *state);

// Process one buffer of interleaved-or-planar float samples in place.
// `samples` holds `frames * channels` samples; `stride` is 1 for planar-per-channel
// buffers and the channel count for interleaved buffers. No allocation, no locks.
FOUNDATION_EXPORT void YTEQAudioEngineProcess(YTEQState *state, float *samples,
                                              UInt32 frames, UInt32 stride,
                                              UInt32 channels);

// Magnitude of the whole EQ chain at `freq`, in dB. Used to draw the response graph.
FOUNDATION_EXPORT double YTEQResponseDB(const YTEQBand *bands, double preampDB,
                                        double freq, double sampleRate);

// dB -> linear.
FOUNDATION_EXPORT double YTEQDBToLinear(double db);

// Q <-> bandwidth in octaves.
//
// A raw 0.1-12.0 Q slider is unusable: the top of the range does almost nothing and the
// bottom is a full-range wash. These map Q onto the -3 dB bandwidth of a peaking filter
// instead, which is the axis people actually perceive ("how wide is this band").
//
//   Q = 1  -> 1.39 octaves
//   Q = 0.5 -> ~2.2 octaves
//   Q = 4  -> ~1.2 octaves
//
// The useful Q range for the -3 dB definition bottoms out at ~0.585 octaves of half
// bandwidth; below that the formula has no real solution, so both functions clamp there.
FOUNDATION_EXPORT double YTEQBandwidthOctavesForQ(double q);
FOUNDATION_EXPORT double YTEQQForBandwidthOctaves(double octaves);

// ---- Realtime entry points ----
//
// These are what the render callback calls. They deliberately avoid Objective-C
// messaging, allocation and blocking locks so they are safe on the audio thread.

FOUNDATION_EXPORT BOOL YTEQRealtimeEnabled(void);

// Processes one buffer in place. `sampleRate` is the live rate of the stream; if it
// differs from the rate the coefficients were designed for the coefficients are
// re-derived. That re-derivation uses a trylock, so a busy main thread can never block
// audio: the buffer is processed with the previous coefficients instead.
FOUNDATION_EXPORT void YTEQProcessRealtime(float *samples, UInt32 frames, UInt32 stride,
                                           UInt32 channels, double sampleRate);

// Rate/channel count most recently seen by the audio thread, for the diagnostics row.
FOUNDATION_EXPORT double YTEQObservedSampleRate(void);
FOUNDATION_EXPORT int YTEQObservedChannels(void);

#ifdef __cplusplus
}
#endif

// ---- Objective-C shell: persistence + shared instance ----

@interface YTEQAudioEngine : NSObject

@property (class, nonatomic, readonly) YTEQAudioEngine *shared;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) double preampDB;

// Live parameter accessors. Writing any of these reconfigures the DSP immediately.
- (YTEQBand)bandAtIndex:(NSInteger)index;
- (void)setBand:(YTEQBand)band atIndex:(NSInteger)index;
- (double)frequencyAtIndex:(NSInteger)index;
- (void)setFrequency:(double)hz atIndex:(NSInteger)index;
- (double)gainAtIndex:(NSInteger)index;
- (void)setGain:(double)db atIndex:(NSInteger)index;
- (double)qAtIndex:(NSInteger)index;
- (void)setQ:(double)q atIndex:(NSInteger)index;
- (YTEQFilterType)filterTypeAtIndex:(NSInteger)index;
- (void)setFilterType:(YTEQFilterType)type atIndex:(NSInteger)index;
- (BOOL)isBandEnabledAtIndex:(NSInteger)index;
- (void)setBandEnabled:(BOOL)on atIndex:(NSInteger)index;

// Band selection, so the graph knows which node the user is dragging.
@property (nonatomic, assign) NSInteger selectedBand;

- (void)resetToFlat;
- (void)applyPresetNamed:(NSString *)name;
+ (NSArray<NSString *> *)presetNames;

// Parameter writes take effect on audio immediately but do not touch NSUserDefaults:
// dragging a slider fires hundreds of writes, and synchronising each one would stutter the
// UI thread for no benefit. Presets, Flat and -save are the persistence points.
- (void)save;

// Frequency used for the response graph (the graph is meaningless at the wrong rate).
@property (nonatomic, readonly) double graphSampleRate;

// Feeds the real rate from the render callback. Safe to call from the audio thread.
- (void)noteSampleRateFromAudioThread:(double)sampleRate channels:(int)channels;

// Live snapshot of the state the DSP is currently running, for the graph view.
- (void)copyBandsInto:(YTEQBand *)out count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
