# YTEQ — 10-band parametric EQ with a response graph, per-band Q and preamp

For YouTube on iOS, injected into a sideloaded IPA. Built on the hooking approach taken
from `VolumeBoostYT.dylib`, but the payload is a real EQ instead of a volume multiplier.

## What the graph looks like

An interactive frequency-response plot on a log frequency axis (20 Hz – 20 kHz), with one
draggable handle per band:

- **drag a handle** — horizontal moves the band's centre frequency, vertical moves its gain
- **the handle sits on the curve**, so it reads as "this is the bump you are moving"
- **the shaded column under each handle** is that band's Q, drawn as its width in octaves,
  so the one parameter the graph has no axis for is still visible
- **the dashed orange line** is the preamp, which offsets the whole curve
- **band list below** — tap a row to select it, then edit frequency / gain / Q / shape

## Parameters

| | Range | Notes |
|---|---|---|
| Preamp | ±15 dB | master gain applied **before** the cascade |
| Band frequency | 20 Hz – 20 kHz | movable, so this is parametric, not a graphic EQ |
| Band gain | ±15 dB | |
| Band Q | 0.1 – 12 | slider runs on bandwidth in octaves (0.12 – 6.7) |
| Band shape | peak, low shelf, high shelf, low pass, high pass, band pass, notch | |

Q is driven through bandwidth in octaves rather than shown as a raw 0.1–12 slider, because
a linear Q slider spends most of its travel in a range that sounds identical. Q itself
stays the authoritative parameter in the DSP.

Q is clamped per shape, which is not cosmetic:

- **shelves** are pinned to RBJ `S = 1`. Driving a shelf's transition slope from a peak
  filter's Q makes it ring — a "+15 dB low shelf" could peak at +21 dB.
- **low/high pass** are capped at Q = 2. RBJ's low-pass puts its resonant peak on `f0`,
  rising as `20·log10(Q / sin(w0))`; at Q = 12 that is +21 dB of whistle on something the
  UI labels a plain low-pass.
- **band pass / notch** are left alone; their peak is pinned at 0 dB and their null at −∞.

Presets: Flat, Bass Boost, Treble Boost, Vocal, Rock, Pop, Hip-Hop, Electronic, Jazz,
Classical, Loudness.

## What was kept from VolumeBoostYT.dylib, and what changed

Reverse engineering the attached dylib showed its whole architecture, and that is what this
keeps:

- **No tweak framework.** It has no Substrate/ElleKit linkage; it hooks with the plain
  Objective-C runtime (`class_addMethod` / `method_setImplementation`, walking the
  superclass chain). Sideloadly's "inject dylib" is therefore enough to load it, and the
  build is plain `clang`, not Theos.
- **Process guard.** Injected dylibs load into more than one process; both bail out of
  SpringBoard.
- **`NSUserDefaults`-backed switch**, injected into YouTube's own settings list through
  `YTSettingsSectionItemManager` and
  `-switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:`.
  Every private selector is reached through `respondsToSelector:`, so a YouTube update that
  renames one degrades the entry point instead of crashing.

What changed is the payload. VolumeBoostYT hooks `-setVolume:` on `AVPlayer`,
`AVAudioPlayer`, `AVAudioPlayerNode` and `AVSampleBufferAudioRenderer` and multiplies by
`powf(200, (boost - 1) / 19)` — that is how it pushes an app past 100% **without touching a
single sample**. Scaling one scalar cannot shape a spectrum, so:

- the audio hook moved to `AudioUnitSetProperty` +
  `kAudioUnitProperty_SetRenderCallback` (dyld interposition, since that is a C symbol and
  cannot be method-swizzled), wrapping the RemoteIO render callback and processing the
  `AudioBufferList` it is handed;
- the graph is drawn from the same biquad cascade that runs on the audio, via an analytic
  magnitude response, so the picture and the sound cannot disagree.

## Layout

| File | Role |
|---|---|
| `YTEQ/YTEQAudioEngine.h/.m` | coefficient design (RBJ), the processing loop, persistence, presets |
| `YTEQ/YTEQAudioHook.h/.m` | interposes `AudioUnitSetProperty`, wraps the render callback |
| `YTEQ/YTEQGraphView.h/.m` | the response plot and the draggable handles |
| `YTEQ/YTEQPanelViewController.h/.m` | preamp / band / Q / shape controls and the band list |
| `YTEQ/YTEQSwizzle.h/.m` | the runtime swizzle helper lifted from VolumeBoostYT's approach |
| `YTEQ/YTEQBootstrap.h/.m` | constructor, process guard, YouTube settings injection |

The DSP core is plain C over a shared struct. The render callback calls into it without any
Objective-C messaging, allocation or blocking locks, and re-derives coefficients under a
`trylock` so a busy main thread can never block audio.

## Build

No Theos. A macOS runner and Apple's clang are enough:

```sh
make            # -> YTEQ.dylib (universal arm64 + arm64e)
```

Or push and run the `Build YTEQ` GitHub Action, which downloads `YTEQ-sideloadly.zip`.

The workflow fails the build if the dylib links Substrate/ElleKit, or if
`__DATA,__interpose` is missing — without that section the render-callback hook is dead and
the EQ would silently do nothing.

## Install

```sh
python inject_yteq.py "C:\path\to\youtube.ipa" YTEQ.dylib YouTube-YTEQ.ipa
```

Then in Sideloadly: select that IPA, enable **Inject dylib** under Advanced Options, and
sideload.

## If it does not sound different

Open the panel and read the status line under the power switch:

- **"Waiting for audio output…"** — the dylib loaded, but nothing has installed a render
  callback yet. Play something.
- **"Hooked · play something to activate"** — the render callback is wrapped but no buffer
  has flowed. Play something.
- **"Audio running · 48 kHz · 2 ch"** — the DSP is live.

If it never leaves the first state, the interpose did not take. Check the binary with
`otool -s __DATA __interpose YTEQ.dylib` — an empty section means it will not work.
