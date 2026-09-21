# Sideloadly inject - verified for your IPA

Your IPA: `z8jg5n.ipa` = YouTube 19.34.2, `com.google.ios.youtube`, min iOS 15.0
Base: YTLitePlus-style (16 dylibs in `Frameworks/`: YTLite, YTUHD, iSponsorBlock, etc.)
Main binary is clean (Sideloadly patches `LC_LOAD` at install) - same will happen for YTEQ.

1. Push this folder to GitHub, run Actions -> `Build YTEQ` -> Download `YTEQ-sideloadly.zip`.
   Unzip to get `YTEQ.dylib` + `YTEQ.plist`.

2. Inject locally (tested on your IPA):
   `python inject_yteq.py "C:\Users\Admin\Downloads\z8jg5n.ipa" YTEQ.dylib YouTube-YTEQ.ipa`
   Verified: adds `Payload/YouTube.app/Frameworks/YTEQ.dylib` + `YTEQ.plist` (14178 -> 14180 files).

3. In Sideloadly (Windows):
   - Connect iPhone, select IPA
   - Advanced Options -> check `Inject dylib/framework` / `Tweak Injection`
   - Add `YTEQ.dylib` (ensure companion `YTEQ.plist` is in same folder, same basename)
   - Sideload with your Apple ID (free 7-day cert is fine)

4. Open YouTube -> Settings / Account page -> tap `EQ` top-right.
   - Toggle Enable ON (default ON)
   - Set Preamp first (start 0dB, +3 to +6 if quiet, -3 if clipping)
   - Adjust 10 bands, pick preset if wanted. Settings auto-save live.
   - Force-close + reopen YouTube after first install so tap attaches.

## How it works (so you know it's real)
- `YTEQ/Tweak.x:11` wraps `AudioUnitSetProperty` render callback (RemoteIO - HAMPlayer path) + `AVPlayerItem` tap fallback.
- `YTEQ/YTEQAudioEngine.m:120` creates tap, `processBuffer:frames:sampleRate:channels:` applies preamp gain then 10x peaking biquads (RBJ cookbook, Q=1).
- UI is in `YTEQ/YTEQSettingsViewController.m:30`.

## Troubleshooting
- No EQ button: open YouTube Settings tab, kill + reopen app. Hook matches any VC with `Settings/Account/YT` in name.
- No audible change: check Enable=ON, raise Preamp to +3dB, set 32Hz to +8 for test (bass obvious).
- Distortion: lower Preamp to -3dB. Preamp runs before EQ precisely to avoid clipping.
- Sideloadly inject fails: dylib must be arm64 (built by Action), plist Filter Bundles must contain youtube. Both are auto-set.
