#import "YTEQAudioEngine.h"
#import <math.h>
#import <os/lock.h>
#import <stdatomic.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ---------------------------------------------------------------------------
// Coefficient design
// ---------------------------------------------------------------------------

double YTEQDBToLinear(double db) {
    return pow(10.0, db / 20.0);
}

static inline double YTEQClamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Half bandwidth in octaves for the -3 dB points, using the constant-Q bandpass
// definition that parametric-EQ UIs traditionally map Q onto:
//
//   h = log2( sqrt(1 + 1/(4Q^2)) + 1/(2Q) )
//
// Writing u = 2^h and inverting:
//
//   u = sqrt(1 + 1/(4Q^2)) + 1/(2Q)
//   (u - 1/(2Q))^2 = 1 + 1/(4Q^2)
//   u^2 - u/Q = 1
//   Q = u / (u^2 - 1)
//
// Limits: Q -> inf gives u -> 1, so h -> 0 and the width goes to zero; Q -> 0 gives
// u -> infinity. So there is no floor to clamp at, only the u^2 - 1 <= 0 guard on the way
// back. Over Q in [0.1, 12] this spans about 0.12 to 6.67 octaves.
//
// Caveat worth stating plainly: this is the bandpass definition. A peaking filter's own
// -3 dB width also depends on its gain, so the octave figure is an approximation. It is
// used because it is the axis people can actually feel, and because Q itself remains the
// authoritative parameter everywhere in the DSP.
double YTEQBandwidthOctavesForQ(double q) {
    if (!(q > 0.0)) q = 1.0;
    // u > 1 strictly for every finite q, so h > 0 and log2 is safe.
    double u = sqrt(1.0 + 1.0 / (4.0 * q * q)) + 1.0 / (2.0 * q);
    double h = log2(u);
    return (h == h) ? 2.0 * h : 0.0;
}

double YTEQQForBandwidthOctaves(double octaves) {
    if (!(octaves > 0.0)) return YTEQ_MAX_Q;
    double u = pow(2.0, octaves * 0.5);
    double under = u * u - 1.0;
    if (under <= 1e-12) return YTEQ_MAX_Q;
    return YTEQClamp(u / under, YTEQ_MIN_Q, YTEQ_MAX_Q);
}

// Not every filter shape wants the same Q.
//
// The RBJ designs all take the same alpha = sin(w0)/(2Q), but alpha means different things
// per shape, and reusing one user-facing Q across all of them produces two real artefacts:
//
//   * A low-pass / high-pass at alpha = sin(w0)/(2Q) has its resonant peak sitting on f0,
//     rising as 20*log10(Q / sin(w0)). At Q = 12 that is +21 dB of whistle on what the UI
//     labels a plain low-pass. Capped to [0.5, 2] here, which is the musical range.
//   * A shelf's alpha sets the transition slope, not a Q. Driving it from a peak filter's
//     Q makes the transition ring: a "+15 dB low shelf" could peak at +21 dB. Pinning it to
//     1/sqrt(2) is exactly RBJ's S = 1, which is monotone between the two asymptotes.
//
// Band-pass and notch are fine as-is: their peak is pinned at 0 dB and their null is at
// -inf regardless of Q.
static double YTEQClampQForType(YTEQFilterType type, double q) {
    switch (type) {
        case YTEQFilterTypeLowShelf:
        case YTEQFilterTypeHighShelf:
            return 0.7071067811865476; // RBJ S = 1
        case YTEQFilterTypeLowPass:
        case YTEQFilterTypeHighPass:
            return YTEQClamp(q, 0.5, 2.0);
        default:
            return YTEQClamp(q, YTEQ_MIN_Q, YTEQ_MAX_Q);
    }
}

void YTEQDesignCoeffs(YTEQCoeffs *out, YTEQFilterType type, double sampleRate,
                      double freq, double gainDB, double q) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));

    if (sampleRate < 8000.0) sampleRate = 44100.0;
    freq = YTEQClamp(freq, YTEQ_MIN_FREQ, YTEQ_MAX_FREQ);
    // Keep the centre below Nyquist. A 16 kHz band on a 44.1 kHz stream is legal in
    // principle but drives tan(w0/2) in the shelf designs to a huge number, which turns
    // the shelf coefficients into noise, so clamp with headroom.
    double nyquistLimit = sampleRate * 0.49;
    if (freq > nyquistLimit) freq = nyquistLimit;
    q = YTEQClampQForType(type, q);

    double A     = pow(10.0, gainDB / 40.0);
    double w0    = 2.0 * M_PI * freq / sampleRate;
    double cw    = cos(w0);
    double alpha = sin(w0) / (2.0 * q);

    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0;

    switch (type) {
        case YTEQFilterTypeLowShelf: {
            double t = 2.0 * sqrt(A) * alpha;
            b0 =  A * ((A + 1.0) - (A - 1.0) * cw + t);
            b1 = 2 * A * ((A - 1.0) - (A + 1.0) * cw);
            b2 =  A * ((A + 1.0) - (A - 1.0) * cw - t);
            a0 =       (A + 1.0) + (A - 1.0) * cw + t;
            a1 =  -2.0 * ((A - 1.0) + (A + 1.0) * cw);
            a2 =       (A + 1.0) + (A - 1.0) * cw - t;
            break;
        }
        case YTEQFilterTypeHighShelf: {
            double t = 2.0 * sqrt(A) * alpha;
            b0 =  A * ((A + 1.0) + (A - 1.0) * cw + t);
            b1 = -2 * A * ((A - 1.0) + (A + 1.0) * cw);
            b2 =  A * ((A + 1.0) + (A - 1.0) * cw - t);
            a0 =       (A + 1.0) - (A - 1.0) * cw + t;
            a1 =   2.0 * ((A - 1.0) - (A + 1.0) * cw);
            a2 =       (A + 1.0) - (A - 1.0) * cw - t;
            break;
        }
        case YTEQFilterTypeLowPass: {
            b0 = (1.0 - cw) / 2.0;
            b1 = 1.0 - cw;
            b2 = (1.0 - cw) / 2.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cw;
            a2 = 1.0 - alpha;
            break;
        }
        case YTEQFilterTypeHighPass: {
            b0 = (1.0 + cw) / 2.0;
            b1 = -(1.0 + cw);
            b2 = (1.0 + cw) / 2.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cw;
            a2 = 1.0 - alpha;
            break;
        }
        case YTEQFilterTypeBandPass: {
            b0 = alpha;
            b1 = 0.0;
            b2 = -alpha;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cw;
            a2 = 1.0 - alpha;
            break;
        }
        case YTEQFilterTypeNotch: {
            b0 = 1.0;
            b1 = -2.0 * cw;
            b2 = 1.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cw;
            a2 = 1.0 - alpha;
            break;
        }
        case YTEQFilterTypeParametric:
        default:
            b0 = 1.0 + alpha * A;
            b1 = -2.0 * cw;
            b2 = 1.0 - alpha * A;
            a0 = 1.0 + alpha / A;
            a1 = -2.0 * cw;
            a2 = 1.0 - alpha / A;
            break;
    }

    if (a0 == 0.0 || !isfinite(a0) || !isfinite(b0)) {
        memset(out, 0, sizeof(*out));
        out->b0 = 1.0;
        return;
    }

    out->b0 = b0 / a0;
    out->b1 = b1 / a0;
    out->b2 = b2 / a0;
    out->a1 = a1 / a0;
    out->a2 = a2 / a0;
}

// ---------------------------------------------------------------------------
// Processing
// ---------------------------------------------------------------------------

static inline BOOL YTEQCoeffsAreIdentity(const YTEQCoeffs *c) {
    return c->b0 == 1.0 && c->b1 == 0.0 && c->b2 == 0.0 && c->a1 == 0.0 && c->a2 == 0.0;
}

// Shared by both configure paths: design every band, work out which ones actually change
// anything, and store the coefficients. Deciding that here rather than per sample is the
// difference between 10 multiply-adds per frame and only the active ones.
static void YTEQStoreCoefficients(YTEQState *state, const YTEQBand *bands, double sampleRate) {
    uint32_t mask = 0;
    for (int b = 0; b < YTEQ_NUM_BANDS; b++) {
        YTEQCoeffs c;
        memset(&c, 0, sizeof(c));
        c.b0 = 1.0;
        if (bands != NULL && bands[b].enabled) {
            YTEQDesignCoeffs(&c, (YTEQFilterType)bands[b].type, sampleRate,
                             bands[b].freq, bands[b].gainDB, bands[b].q);
        }
        if (!YTEQCoeffsAreIdentity(&c)) mask |= (1u << b);
        for (int ch = 0; ch < YTEQ_MAX_CHANNELS; ch++) state->stage[b][ch].c = c;
    }
    state->activeMask = mask;
}

void YTEQStateConfigure(YTEQState *state, const YTEQBand *bands, double preampDB,
                        double sampleRate, int channelCount, BOOL enabled) {
    if (state == NULL) return;
    if (sampleRate < 8000.0) sampleRate = 44100.0;
    if (channelCount < 1) channelCount = 2;
    if (channelCount > YTEQ_MAX_CHANNELS) channelCount = YTEQ_MAX_CHANNELS;

    state->sampleRate   = sampleRate;
    state->channelCount = channelCount;
    state->enabled      = enabled;
    state->preampLin    = enabled
        ? YTEQDBToLinear(YTEQClamp(preampDB, YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP)) : 1.0;

    YTEQStoreCoefficients(state, bands, sampleRate);

    for (int b = 0; b < YTEQ_NUM_BANDS; b++) {
        for (int ch = 0; ch < YTEQ_MAX_CHANNELS; ch++) {
            state->stage[b][ch].x1 = 0.0;
            state->stage[b][ch].x2 = 0.0;
            state->stage[b][ch].y1 = 0.0;
            state->stage[b][ch].y2 = 0.0;
        }
    }
}

void YTEQStateUpdateCoefficients(YTEQState *state, const YTEQBand *bands,
                                 double preampDB, BOOL enabled) {
    if (state == NULL) return;
    double sampleRate = state->sampleRate > 0.0 ? state->sampleRate : 44100.0;

    state->enabled   = enabled;
    state->preampLin = enabled
        ? YTEQDBToLinear(YTEQClamp(preampDB, YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP)) : 1.0;

    // Coefficients only. x1/x2/y1/y2 stay put, otherwise dragging a slider would restart
    // every filter from rest and retrigger it on every tick.
    YTEQStoreCoefficients(state, bands, sampleRate);
}

void YTEQStateReset(YTEQState *state) {
    if (state == NULL) return;
    for (int b = 0; b < YTEQ_NUM_BANDS; b++) {
        for (int ch = 0; ch < YTEQ_MAX_CHANNELS; ch++) {
            state->stage[b][ch].x1 = 0.0;
            state->stage[b][ch].x2 = 0.0;
            state->stage[b][ch].y1 = 0.0;
            state->stage[b][ch].y2 = 0.0;
        }
    }
}

// Direct Form I. Transposed DF-II is cheaper in registers, but DF-I keeps all four
// history words next to the coefficients in a single struct and behaves predictably when
// a coefficient changes mid-stream.
static inline double YTEQRunStage(YTEQStage *s, double x) {
    double y = s->c.b0 * x + s->c.b1 * s->x1 + s->c.b2 * s->x2
             - s->c.a1 * s->y1 - s->c.a2 * s->y2;
    s->x2 = s->x1;
    s->x1 = x;
    s->y2 = s->y1;
    s->y1 = y;
    return y;
}

static inline BOOL YTEQCoeffsAreIdentity(const YTEQCoeffs *c) {
    return c->b0 == 1.0 && c->b1 == 0.0 && c->b2 == 0.0 && c->a1 == 0.0 && c->a2 == 0.0;
}

void YTEQAudioEngineProcess(YTEQState *state, float *samples, UInt32 frames,
                            UInt32 stride, UInt32 channels) {
    if (state == NULL || samples == NULL || frames == 0) return;
    if (!state->enabled) return;

    if (channels == 0) channels = 1;
    if (channels > YTEQ_MAX_CHANNELS) channels = YTEQ_MAX_CHANNELS;
    if (stride == 0) stride = 1;

    const double preamp = state->preampLin;
    const int    chans  = (int)channels;
    const size_t limit  = (size_t)frames * (size_t)stride;
    const uint32_t mask = state->activeMask;

    // Nothing active and unity preamp: leave the buffer completely alone. This is the
    // common case (flat EQ) and it keeps a disabled/flat tweak free.
    if (mask == 0 && preamp == 1.0) return;

    for (UInt32 i = 0; i < frames; i++) {
        const size_t base = (size_t)i * (size_t)stride;
        for (int ch = 0; ch < chans; ch++) {
            const size_t idx = base + (size_t)ch;
            if (idx >= limit) break;

            double x = (double)samples[idx] * preamp;
            uint32_t m = mask;
            while (m != 0) {
                int b = __builtin_ctz(m);
                m &= m - 1;
                x = YTEQRunStage(&state->stage[b][ch], x);
            }

            // Guard rail, not a limiter. Clamping hard at +/-1.0 turns an over-boosted
            // peak into a square wave; this only catches runaway instability, which with
            // the coefficient clamping in YTEQDesignCoeffs should never happen.
            if (x > 8.0) x = 8.0;
            else if (x < -8.0) x = -8.0;
            samples[idx] = (float)x;
        }
    }
}

double YTEQResponseDB(const YTEQBand *bands, double preampDB, double freq, double sampleRate) {
    if (bands == NULL) return YTEQClamp(preampDB, YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP);
    if (sampleRate < 8000.0) sampleRate = 44100.0;

    double total = YTEQClamp(preampDB, YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP);
    for (int b = 0; b < YTEQ_NUM_BANDS; b++) {
        if (!bands[b].enabled) continue;

        YTEQCoeffs c;
        YTEQDesignCoeffs(&c, (YTEQFilterType)bands[b].type, sampleRate,
                         bands[b].freq, bands[b].gainDB, bands[b].q);
        if (YTEQCoeffsAreIdentity(&c)) continue;

        double w  = 2.0 * M_PI * freq / sampleRate;
        double cw = cos(w), sw = sin(w);
        double c2 = cos(2.0 * w), s2 = sin(2.0 * w);

        double nr = c.b0 + c.b1 * cw + c.b2 * c2;
        double ni = -(c.b1 * sw + c.b2 * s2);
        double dr = 1.0 + c.a1 * cw + c.a2 * c2;
        double di = -(c.a1 * sw + c.a2 * s2);

        double num = nr * nr + ni * ni;
        double den = dr * dr + di * di;
        if (den <= 0.0) continue;
        // A notch has an exact zero at its centre frequency, so num can be 0 and log10
        // would be -inf. The graph would draw a spike to the floor of the plot; clamping
        // reports it as "as deep as the graph can show" instead.
        if (num < 1e-18) num = 1e-18;
        total += 10.0 * log10(num / den);
    }
    return total;
}

// ---------------------------------------------------------------------------
// Shared core
// ---------------------------------------------------------------------------
//
// All state lives in a plain C struct so the render callback never touches an
// Objective-C object. The shell below is only persistence and UI plumbing.

typedef struct {
    YTEQBand  bands[YTEQ_NUM_BANDS];
    double    preampDB;
    BOOL      enabled;
    BOOL      initialised;
    YTEQState state;
} YTEQCore;

static YTEQCore      YTEQCoreStorage;
static os_unfair_lock YTEQCoreLock = OS_UNFAIR_LOCK_INIT;

static _Atomic double YTEQObservedRateStorage    = 48000.0;
static _Atomic int    YTEQObservedChannelStorage = 2;

static YTEQBand YTEQMakeDefaultBand(NSInteger index) {
    YTEQBand b;
    memset(&b, 0, sizeof(b));
    b.freq    = YTEQ_DEFAULT_FREQ(index);
    b.gainDB  = 0.0;
    b.q       = 1.0;
    b.type    = YTEQFilterTypeParametric;
    b.enabled = YES;
    return b;
}

// Derive coefficients from the core's parameters. Caller holds the lock (or is the audio
// thread holding it via trylock).
static void YTEQRecomputeLocked(BOOL resetMemory) {
    YTEQCore *c = &YTEQCoreStorage;
    if (resetMemory) {
        YTEQStateConfigure(&c->state, c->bands, c->preampDB, c->state.sampleRate,
                           c->state.channelCount, c->enabled);
    } else {
        YTEQStateUpdateCoefficients(&c->state, c->bands, c->preampDB, c->enabled);
    }
}

static void YTEQCoreBoot(void) {
    os_unfair_lock_lock(&YTEQCoreLock);
    if (!YTEQCoreStorage.initialised) {
        for (int i = 0; i < YTEQ_NUM_BANDS; i++) {
            YTEQCoreStorage.bands[i] = YTEQMakeDefaultBand(i);
        }
        YTEQCoreStorage.preampDB     = 0.0;
        YTEQCoreStorage.enabled      = YES;
        YTEQCoreStorage.initialised  = YES;
        YTEQStateConfigure(&YTEQCoreStorage.state, YTEQCoreStorage.bands, 0.0,
                           48000.0, 2, YES);
    }
    os_unfair_lock_unlock(&YTEQCoreLock);
}

// ---------------------------------------------------------------------------
// Realtime entry points
// ---------------------------------------------------------------------------

BOOL YTEQRealtimeEnabled(void) {
    // Plain read. A stale read here only means the render callback processes or skips one
    // buffer, and BOOL is a single byte, so this is atomic in practice.
    return YTEQCoreStorage.enabled;
}

double YTEQObservedSampleRate(void) {
    return atomic_load_explicit(&YTEQObservedRateStorage, memory_order_relaxed);
}

int YTEQObservedChannels(void) {
    return atomic_load_explicit(&YTEQObservedChannelStorage, memory_order_relaxed);
}

void YTEQProcessRealtime(float *samples, UInt32 frames, UInt32 stride,
                         UInt32 channels, double sampleRate) {
    if (samples == NULL || frames == 0) return;

    YTEQCore *core = &YTEQCoreStorage;
    if (!core->enabled) return;

    // The live rate can differ between players, or change mid-session. Re-deriving under
    // a trylock keeps the audio thread unblockable: worst case this buffer renders with
    // slightly stale coefficients and the next one is correct.
    if (sampleRate > 0.0 && fabs(core->state.sampleRate - sampleRate) > 1.0) {
        if (os_unfair_lock_trylock(&YTEQCoreLock)) {
            if (channels > 0 && channels <= YTEQ_MAX_CHANNELS) {
                core->state.channelCount = (int)channels;
            }
            YTEQRecomputeLocked(YES);
            os_unfair_lock_unlock(&YTEQCoreLock);
        }
    }

    // Diagnostics for the settings screen. Written every buffer so the row is correct the
    // moment audio starts, not only after a rate change.
    if (sampleRate > 0.0) {
        atomic_store_explicit(&YTEQObservedRateStorage, sampleRate, memory_order_relaxed);
    }
    if (channels > 0) {
        atomic_store_explicit(&YTEQObservedChannelStorage, (int)channels, memory_order_relaxed);
    }

    YTEQAudioEngineProcess(&core->state, samples, frames, stride ? stride : 1,
                           channels ? channels : 1);
}

// ---------------------------------------------------------------------------
// Objective-C shell
// ---------------------------------------------------------------------------

static NSString * const kYTEQDefaultsKey = @"YTEQ.settings.v1";

@implementation YTEQAudioEngine

+ (YTEQAudioEngine *)shared {
    static YTEQAudioEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        YTEQCoreBoot();
        [self loadSettings];
    }
    return self;
}

#pragma mark - Persistence

- (void)loadSettings {
    NSDictionary *root = [[NSUserDefaults standardUserDefaults] objectForKey:kYTEQDefaultsKey];
    if (![root isKindOfClass:[NSDictionary class]]) return;

    os_unfair_lock_lock(&YTEQCoreLock);
    id en = root[@"enabled"];
    if ([en isKindOfClass:[NSNumber class]]) YTEQCoreStorage.enabled = [en boolValue];
    id pa = root[@"preamp"];
    if ([pa isKindOfClass:[NSNumber class]]) {
        YTEQCoreStorage.preampDB = YTEQClamp([pa doubleValue], YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP);
    }

    NSArray *bands = root[@"bands"];
    if ([bands isKindOfClass:[NSArray class]] && (NSUInteger)bands.count == YTEQ_NUM_BANDS) {
        for (NSUInteger i = 0; i < YTEQ_NUM_BANDS; i++) {
            NSDictionary *d = bands[i];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSNumber *f = d[@"f"], *g = d[@"g"], *q = d[@"q"], *t = d[@"t"], *e = d[@"e"];
            if ([f isKindOfClass:[NSNumber class]]) {
                YTEQCoreStorage.bands[i].freq = YTEQClamp(f.doubleValue, YTEQ_MIN_FREQ, YTEQ_MAX_FREQ);
            }
            if ([g isKindOfClass:[NSNumber class]]) {
                YTEQCoreStorage.bands[i].gainDB = YTEQClamp(g.doubleValue, YTEQ_MIN_GAIN, YTEQ_MAX_GAIN);
            }
            if ([q isKindOfClass:[NSNumber class]]) {
                YTEQCoreStorage.bands[i].q = YTEQClamp(q.doubleValue, YTEQ_MIN_Q, YTEQ_MAX_Q);
            }
            if ([t isKindOfClass:[NSNumber class]]) {
                YTEQCoreStorage.bands[i].type = (int)t.integerValue;
            }
            if ([e isKindOfClass:[NSNumber class]]) {
                YTEQCoreStorage.bands[i].enabled = e.boolValue;
            }
        }
    }
    YTEQRecomputeLocked(YES);
    os_unfair_lock_unlock(&YTEQCoreLock);
}

- (void)save {
    NSMutableArray *bands = [NSMutableArray arrayWithCapacity:YTEQ_NUM_BANDS];
    double preamp;
    BOOL enabled;
    os_unfair_lock_lock(&YTEQCoreLock);
    for (int i = 0; i < YTEQ_NUM_BANDS; i++) {
        YTEQBand b = YTEQCoreStorage.bands[i];
        [bands addObject:@{ @"f" : @(b.freq), @"g" : @(b.gainDB), @"q" : @(b.q),
                            @"t" : @(b.type),  @"e" : @(b.enabled ? YES : NO) }];
    }
    preamp = YTEQCoreStorage.preampDB;
    enabled = YTEQCoreStorage.enabled;
    os_unfair_lock_unlock(&YTEQCoreLock);

    NSDictionary *root = @{ @"enabled" : @(enabled), @"preamp" : @(preamp), @"bands" : bands };
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:root forKey:kYTEQDefaultsKey];
    [d synchronize];
}

#pragma mark - Reconfiguration

// `reset` YES after a preset or a rate change (filter memory is meaningless then), NO for
// interactive edits so each band keeps its history and sweeps do not click.
- (void)reconfigureWithReset:(BOOL)reset {
    os_unfair_lock_lock(&YTEQCoreLock);
    YTEQRecomputeLocked(reset);
    os_unfair_lock_unlock(&YTEQCoreLock);
}

// Reconfigure + notify. Deliberately does not persist: an interactive drag issues one
// of these per touch-move and NSUserDefaults writes are far too expensive for that.
- (void)applyChangesResettingMemory:(BOOL)reset {
    [self reconfigureWithReset:reset];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTEQSettingsDidChange"
                                                        object:self];
}

#pragma mark - Parameter access

- (YTEQBand)bandAtIndex:(NSInteger)index {
    if (index < 0 || index >= YTEQ_NUM_BANDS) return YTEQMakeDefaultBand(0);
    os_unfair_lock_lock(&YTEQCoreLock);
    YTEQBand b = YTEQCoreStorage.bands[index];
    os_unfair_lock_unlock(&YTEQCoreLock);
    return b;
}

- (void)setBand:(YTEQBand)band atIndex:(NSInteger)index {
    if (index < 0 || index >= YTEQ_NUM_BANDS) return;
    os_unfair_lock_lock(&YTEQCoreLock);
    YTEQCoreStorage.bands[index].freq    = YTEQClamp(band.freq, YTEQ_MIN_FREQ, YTEQ_MAX_FREQ);
    YTEQCoreStorage.bands[index].gainDB  = YTEQClamp(band.gainDB, YTEQ_MIN_GAIN, YTEQ_MAX_GAIN);
    YTEQCoreStorage.bands[index].q       = YTEQClamp(band.q, YTEQ_MIN_Q, YTEQ_MAX_Q);
    YTEQCoreStorage.bands[index].type    = (int)band.type;
    YTEQCoreStorage.bands[index].enabled = band.enabled;
    os_unfair_lock_unlock(&YTEQCoreLock);
    [self applyChangesResettingMemory:NO];
}

- (double)frequencyAtIndex:(NSInteger)index { return [self bandAtIndex:index].freq; }
- (double)gainAtIndex:(NSInteger)index     { return [self bandAtIndex:index].gainDB; }
- (double)qAtIndex:(NSInteger)index         { return [self bandAtIndex:index].q; }

- (void)setFrequency:(double)hz atIndex:(NSInteger)index {
    YTEQBand b = [self bandAtIndex:index]; b.freq = hz;  [self setBand:b atIndex:index];
}

- (void)setGain:(double)db atIndex:(NSInteger)index {
    YTEQBand b = [self bandAtIndex:index]; b.gainDB = db; [self setBand:b atIndex:index];
}

- (void)setQ:(double)q atIndex:(NSInteger)index {
    YTEQBand b = [self bandAtIndex:index]; b.q = q; [self setBand:b atIndex:index];
}

- (YTEQFilterType)filterTypeAtIndex:(NSInteger)index {
    return (YTEQFilterType)[self bandAtIndex:index].type;
}

- (void)setFilterType:(YTEQFilterType)type atIndex:(NSInteger)index {
    YTEQBand b = [self bandAtIndex:index]; b.type = (int)type; [self setBand:b atIndex:index];
}

- (BOOL)isBandEnabledAtIndex:(NSInteger)index { return [self bandAtIndex:index].enabled; }

- (void)setBandEnabled:(BOOL)on atIndex:(NSInteger)index {
    YTEQBand b = [self bandAtIndex:index]; b.enabled = on; [self setBand:b atIndex:index];
}

- (void)setEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&YTEQCoreLock);
    BOOL changed = (YTEQCoreStorage.enabled != enabled);
    YTEQCoreStorage.enabled = enabled;
    os_unfair_lock_unlock(&YTEQCoreLock);
    if (!changed) return;
    [self applyChangesResettingMemory:YES];
}

- (void)setPreampDB:(double)preampDB {
    preampDB = YTEQClamp(preampDB, YTEQ_MIN_PREAMP, YTEQ_MAX_PREAMP);
    os_unfair_lock_lock(&YTEQCoreLock);
    BOOL changed = fabs(YTEQCoreStorage.preampDB - preampDB) > 1e-9;
    YTEQCoreStorage.preampDB = preampDB;
    os_unfair_lock_unlock(&YTEQCoreLock);
    if (!changed) return;
    [self applyChangesResettingMemory:NO];
}

- (void)copyBandsInto:(YTEQBand *)out count:(NSUInteger)count {
    if (out == NULL) return;
    os_unfair_lock_lock(&YTEQCoreLock);
    for (NSUInteger i = 0; i < count && i < YTEQ_NUM_BANDS; i++) out[i] = YTEQCoreStorage.bands[i];
    os_unfair_lock_unlock(&YTEQCoreLock);
}

#pragma mark - Diagnostics

- (double)graphSampleRate {
    double rate = YTEQObservedSampleRate();
    return rate > 8000.0 ? rate : 48000.0;
}

- (void)noteSampleRateFromAudioThread:(double)sampleRate channels:(int)channels {
    // Called from the render callback. Keep it to bookkeeping only.
    if (sampleRate > 8000.0) {
        atomic_store_explicit(&YTEQObservedRateStorage, sampleRate, memory_order_relaxed);
    }
    if (channels > 0) {
        atomic_store_explicit(&YTEQObservedChannelStorage, channels, memory_order_relaxed);
    }
}

#pragma mark - Presets

+ (NSArray<NSString *> *)presetNames {
    return @[ @"Flat", @"Bass Boost", @"Treble Boost", @"Vocal", @"Rock",
              @"Pop", @"Hip-Hop", @"Electronic", @"Jazz", @"Classical", @"Loudness" ];
}

- (void)resetToFlat {
    os_unfair_lock_lock(&YTEQCoreLock);
    for (int i = 0; i < YTEQ_NUM_BANDS; i++) YTEQCoreStorage.bands[i] = YTEQMakeDefaultBand(i);
    YTEQRecomputeLocked(YES);
    os_unfair_lock_unlock(&YTEQCoreLock);
    [self save];
    [self applyChangesResettingMemory:YES];
}

// Classic 10-band shapes. Q is not 1.0 everywhere: narrow peaking filters cut a slot out
// of the spectrum that sounds like a hole rather than a tone boost, so the presence bands
// in Vocal/Loudness are widened.
- (void)applyPresetNamed:(NSString *)name {
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *gains;
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *qs;
    static NSArray<NSNumber *> *flatQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flatQ = @[ @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0 ];
        gains = @{ @"Flat"        : @[ @0,  @0,  @0,  @0,  @0,  @0,  @0,  @0,  @0,  @0 ],
                   @"Bass Boost"  : @[ @7,  @6,  @5,  @3,  @1,  @0,  @0,  @0,  @1,  @2 ],
                   @"Treble Boost": @[ @-2, @-1, @0,  @0,  @0,  @1,  @2,  @4,  @6,  @7 ],
                   @"Vocal"       : @[ @-3, @-2, @-1, @1,  @3,  @4,  @4,  @3,  @1,  @0 ],
                   @"Rock"        : @[ @5,  @4,  @3,  @1,  @-1, @0,  @2,  @4,  @5,  @5 ],
                   @"Pop"         : @[ @-1, @0,  @1,  @3,  @4,  @3,  @1,  @0,  @-1, @-1 ],
                   @"Hip-Hop"     : @[ @7,  @6,  @4,  @2,  @0,  @-1, @0,  @1,  @2,  @3 ],
                   @"Electronic"  : @[ @6,  @5,  @2,  @0,  @-2, @1,  @3,  @4,  @5,  @6 ],
                   @"Jazz"        : @[ @4,  @3,  @1,  @2,  @-1, @2,  @4,  @4,  @3,  @2 ],
                   @"Classical"   : @[ @4,  @3,  @2,  @0,  @-1, @0,  @2,  @3,  @4,  @4 ],
                   @"Loudness"    : @[ @8,  @6,  @3,  @0,  @-2, @-1, @2,  @5,  @7,  @8 ] };
        qs = @{ @"Flat"        : flatQ,
                @"Vocal"       : @[ @1.0, @1.0, @1.2, @1.4, @1.8, @2.0, @2.0, @1.8, @1.4, @1.0 ],
                @"Loudness"    : @[ @0.8, @0.9, @1.0, @1.2, @1.5, @1.5, @1.2, @0.9, @0.8, @0.8 ],
                @"Bass Boost"  : @[ @0.7, @0.7, @0.8, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0 ],
                @"Treble Boost": @[ @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @1.0, @0.9, @0.8, @0.7 ],
                @"Rock"        : @[ @0.8, @0.9, @1.0, @1.2, @1.2, @1.0, @1.0, @0.9, @0.8, @0.7 ],
                @"Pop"         : @[ @1.0, @1.0, @1.2, @1.5, @1.5, @1.2, @1.0, @1.0, @1.0, @1.0 ],
                @"Hip-Hop"     : @[ @0.7, @0.8, @1.0, @1.2, @1.0, @0.9, @0.9, @1.0, @1.0, @1.1 ],
                @"Electronic"  : @[ @0.8, @0.8, @0.9, @1.0, @1.2, @1.2, @1.0, @0.9, @0.8, @0.7 ],
                @"Jazz"        : @[ @0.8, @0.9, @1.0, @1.3, @1.3, @1.2, @1.0, @0.9, @0.8, @0.7 ],
                @"Classical"   : @[ @0.7, @0.8, @0.9, @1.0, @1.2, @1.2, @1.0, @0.9, @0.8, @0.7 ] };
    });

    NSArray<NSNumber *> *g = gains[name];
    if (g == nil || (NSUInteger)g.count != YTEQ_NUM_BANDS) return;
    NSArray<NSNumber *> *q = qs[name] ?: flatQ;
    if ((NSUInteger)q.count != YTEQ_NUM_BANDS) q = flatQ;

    os_unfair_lock_lock(&YTEQCoreLock);
    for (int i = 0; i < YTEQ_NUM_BANDS; i++) {
        YTEQCoreStorage.bands[i].gainDB  = YTEQClamp(g[i].doubleValue, YTEQ_MIN_GAIN, YTEQ_MAX_GAIN);
        YTEQCoreStorage.bands[i].q       = YTEQClamp(q[i].doubleValue, YTEQ_MIN_Q, YTEQ_MAX_Q);
        YTEQCoreStorage.bands[i].enabled = YES;
    }
    YTEQRecomputeLocked(YES);
    os_unfair_lock_unlock(&YTEQCoreLock);
    [self save];
    [self applyChangesResettingMemory:YES];
}

@end
