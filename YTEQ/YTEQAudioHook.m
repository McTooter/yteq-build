#import "YTEQAudioHook.h"
#import "YTEQAudioEngine.h"

#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>

// MARK: - Why this file interposes instead of swizzling
//
// VolumeBoostYT.dylib hooks ObjC methods only (class_addMethod /
// method_setImplementation) and gets away with it because all it needs is -setVolume:,
// a scalar multiplier on AVPlayer / AVAudioPlayer / AVAudioPlayerNode /
// AVSampleBufferAudioRenderer. An EQ has to touch every sample, so it needs an
// AudioBufferList, and the only place one exists on the way to the speaker is the RemoteIO
// render callback installed through AudioUnitSetProperty +
// kAudioUnitProperty_SetRenderCallback.
//
// That is a C symbol in AudioToolbox, so method swizzling cannot reach it. Instead we use
// dyld function interposition: the __DATA,__interpose tuple below makes this image's
// YTEQInterposedSetProperty the implementation of AudioUnitSetProperty for every caller in
// the process, and we reach the genuine implementation through RTLD_NEXT.

typedef OSStatus (*YTEQRealSetPropertyFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                          AudioUnitElement, const void *, UInt32);
typedef OSStatus (*YTEQOriginalRenderFn)(void *, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *);

static YTEQRealSetPropertyFn YTEQGetRealSetProperty(void) {
    static YTEQRealSetPropertyFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (YTEQRealSetPropertyFn)dlsym(RTLD_NEXT, "AudioUnitSetProperty"); });
    return fn;
}

// MARK: - Unit registry
//
// Several audio units can exist in one process (the main player plus the preview player),
// so each one gets its own slot. A fixed table rather than a dictionary because this is
// touched from the audio thread and must not allocate.

#define YTEQ_MAX_SLOTS 8

typedef struct {
    AudioUnit          unit;
    YTEQOriginalRenderFn originalProc;
    void              *originalRefCon;
    BOOL               active;
} YTEQUnitSlot;

static YTEQUnitSlot   g_slots[YTEQ_MAX_SLOTS];
static os_unfair_lock g_slotLock = OS_UNFAIRS_LOCK_INIT;
static _Atomic(BOOL)  g_sawAudio = false;

// Registers (or refreshes) the slot for `unit` and returns its index + 1, which is what we
// hand the wrapper as its refCon so it can find its way back without a search.
// Returns 0 when the table is full.
static uintptr_t YTEQRegisterUnit(AudioUnit unit, YTEQOriginalRenderFn proc, void *refCon) {
    uintptr_t token = 0;
    os_unfair_lock_lock(&g_slotLock);
    for (int i = 0; i < YTEQ_MAX_SLOTS; i++) {
        if (g_slots[i].active && g_slots[i].unit == unit) {
            g_slots[i].originalProc    = proc;
            g_slots[i].originalRefCon = refCon;
            token = (uintptr_t)(i + 1);
            break;
        }
    }
    if (token == 0) {
        for (int i = 0; i < YTEQ_MAX_SLOTS; i++) {
            if (!g_slots[i].active) {
                g_slots[i].unit          = unit;
                g_slots[i].originalProc  = proc;
                g_slots[i].originalRefCon = refCon;
                g_slots[i].active        = true;
                token = (uintptr_t)(i + 1);
                break;
            }
        }
    }
    os_unfair_lock_unlock(&g_slotLock);
    return token;
}

static YTEQUnitSlot YTEQSlotForToken(uintptr_t token) {
    YTEQUnitSlot slot;
    memset(&slot, 0, sizeof(slot));
    if (token == 0 || token > (uintptr_t)YTEQ_MAX_SLOTS) return slot;
    // trylock: the table is written once at install and read thousands of times a second,
    // so contention is not expected. On failure fall back to a direct read, which is safe
    // because the entry is fully written before the token is ever handed to the audio
    // thread.
    if (!os_unfair_lock_trylock(&g_slotLock)) return g_slots[token - 1];
    slot = g_slots[token - 1];
    os_unfair_lock_unlock(&g_slotLock);
    return slot;
}

static int YTEQSlotCount(void) {
    int n = 0;
    os_unfair_lock_lock(&g_slotLock);
    for (int i = 0; i < YTEQ_MAX_SLOTS; i++) if (g_slots[i].active) n++;
    os_unfair_lock_unlock(&g_slotLock);
    return n;
}

// MARK: - Render callback

static OSStatus YTEQRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                   UInt32 inNumberFrames, AudioBufferList *ioData) {
    YTEQUnitSlot slot = YTEQSlotForToken((uintptr_t)inRefCon);
    if (!slot.active || slot.originalProc == NULL) return noErr;

    OSStatus status = slot.originalProc(slot.originalRefCon, ioActionFlags, inTimeStamp,
                                        inBusNumber, inNumberFrames, ioData);
    if (status != noErr || ioData == NULL) return status;

    if (!YTEQRealtimeEnabled()) return status;

    // Read the live format each callback instead of caching it: YouTube switches sample
    // rate and channel layout between streams and between its two players.
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    UInt32 fmtSize = (UInt32)sizeof(fmt);
    if (AudioUnitGetProperty(slot.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             0, &fmt, &fmtSize) != noErr) {
        fmtSize = (UInt32)sizeof(fmt);
        if (AudioUnitGetProperty(slot.unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Global, 0, &fmt, &fmtSize) != noErr) {
            return status;
        }
    }
    if (fmt.mSampleRate <= 0.0) return status;

    // Float PCM only. The RemoteIO output bus is float32 on every iOS release this runs
    // on, and guessing at a fixed-point layout would turn silence into noise rather than
    // leaving it alone.
    if (fmt.mFormatID != kAudioFormatLinearPCM) return status;
    if ((fmt.mFormatFlags & kAudioFormatFlagIsFloat) == 0) return status;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer buffer = ioData->mBuffers[b];
        if (buffer.mData == NULL || buffer.mDataByteSize == 0) continue;

        UInt32 channels = buffer.mNumberChannels ? buffer.mNumberChannels : 1;
        // Planar: one channel, stride 1. Interleaved: all channels, stride == channel count.
        UInt32 stride = (channels > 1) ? channels : 1;

        YTEQProcessRealtime((float *)buffer.mData, inNumberFrames, stride, channels,
                            (double)fmt.mSampleRate);
    }

    atomic_store_explicit(&g_sawAudio, true, memory_order_relaxed);
    return status;
}

// MARK: - Interposed AudioUnitSetProperty

static OSStatus YTEQHandleRenderCallback(AudioUnit unit, AudioUnitPropertyID propertyID,
                                         AudioUnitScope scope, AudioUnitElement element,
                                         const void *inData, UInt32 inDataSize) {
    YTEQRealSetPropertyFn real = YTEQGetRealSetProperty();
    if (real == NULL) return noErr;

    if (propertyID != kAudioUnitProperty_SetRenderCallback || inData == NULL ||
        inDataSize < sizeof(AURenderCallbackStruct)) {
        return real(unit, propertyID, scope, element, inData, inDataSize);
    }

    const AURenderCallbackStruct *callback = (const AURenderCallbackStruct *)inData;
    // Already wrapped, or nothing to wrap.
    if (callback->inputProc == NULL || callback->inputProc == YTEQRenderCallback) {
        return real(unit, propertyID, scope, element, inData, inDataSize);
    }

    uintptr_t token = YTEQRegisterUnit(unit, callback->inputProc, callback->inputProcRefCon);
    if (token == 0) {
        // Table full. Pass the callback through untouched rather than dropping audio.
        return real(unit, propertyID, scope, element, inData, inDataSize);
    }

    AURenderCallbackStruct wrapped;
    memset(&wrapped, 0, sizeof(wrapped));
    wrapped.inputProc       = YTEQRenderCallback;
    wrapped.inputProcRefCon = (void *)token;

    return real(unit, propertyID, scope, element, &wrapped, sizeof(wrapped));
}

__attribute__((used))
static OSStatus YTEQInterposedSetProperty(AudioUnit unit, AudioUnitPropertyID propertyID,
                                          AudioUnitScope scope, AudioUnitElement element,
                                          const void *inData, UInt32 inDataSize) {
    if (propertyID == kAudioUnitProperty_SetRenderCallback) {
        return YTEQHandleRenderCallback(unit, propertyID, scope, element, inData, inDataSize);
    }
    YTEQRealSetPropertyFn real = YTEQGetRealSetProperty();
    return real ? real(unit, propertyID, scope, element, inData, inDataSize) : noErr;
}

// The replacee is given as a string so this does not depend on an import of
// AudioUnitSetProperty resolving to a non-interposed pointer at load time.
__attribute__((used))
static struct {
    const void *replacement;
    const void *replacee;
} YTEQInterposeSetProperty __attribute__((section("__DATA,__interpose"))) = {
    (const void *)YTEQInterposedSetProperty,
    (const void *)"AudioUnitSetProperty",
};

// MARK: - Diagnostics

@implementation YTEQAudioHook

+ (void)install {
    // Nothing to do. The interpose tuple is live from image load, which is before
    // AudioToolbox can have installed any render callback. This exists so the constructor
    // reads the same as the rest of the tweak and to give future hooks a home.
    (void)YTEQGetRealSetProperty();
}

+ (BOOL)renderCallbackInstalled { return YTEQSlotCount() > 0; }

+ (BOOL)hasSeenAudio { return atomic_load_explicit(&g_sawAudio, memory_order_relaxed); }

+ (double)observedSampleRate { return YTEQObservedSampleRate(); }

+ (int)observedChannels { return YTEQObservedChannels(); }

@end
