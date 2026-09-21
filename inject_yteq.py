#!/usr/bin/env python3
"""Insert built YTEQ.dylib into YTLitePlus-style YouTube IPA (Windows-safe, no codesign).
Sideloadly / TrollStore patch + sign at install time, so we only do zip surgery.

Usage:
  python inject_yteq.py "C:\\Users\\Admin\\Downloads\\z8jg5n.ipa" YTEQ.dylib [YouTube-YTEQ.ipa]

What it does:
- copies input IPA -> output IPA
- adds Payload/YouTube.app/Frameworks/YTEQ.dylib
- adds Payload/YouTube.app/Frameworks/YTEQ.plist (Substrate/ElleKit filter for com.google.ios.youtube)
- verifies bundle id still com.google.ios.youtube
"""
import sys, shutil, zipfile, plistlib, pathlib

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    src = pathlib.Path(sys.argv[1])
    dylib = pathlib.Path(sys.argv[2])
    dst = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else src.parent / "YouTube-YTEQ.ipa"
    assert src.exists(), f"IPA not found: {src}"
    assert dylib.exists(), f"YTEQ.dylib not found: {dylib} -- build via GitHub Actions first"
    assert dylib.stat().st_size > 10000, "dylib looks too small, bad build?"
    shutil.copyfile(src, dst)
    # read bundle id
    with zipfile.ZipFile(dst, 'a', zipfile.ZIP_DEFLATED) as z:
        try:
            info_data = z.read('Payload/YouTube.app/Info.plist')
            pl = plistlib.loads(info_data)
            print(f"Bundle: {pl.get('CFBundleIdentifier')} v{pl.get('CFBundleShortVersionString')} minOS {pl.get('MinimumOSVersion')}")
            assert pl.get('CFBundleIdentifier') == 'com.google.ios.youtube'
        except KeyError:
            print("WARN: Info.plist not found, continuing")
        # write dylib
        arc = 'Payload/YouTube.app/Frameworks/YTEQ.dylib'
        print(f"Injecting {dylib} -> {arc} ({dylib.stat().st_size} bytes)")
        with open(dylib, 'rb') as f:
            z.writestr(arc, f.read())
        # substrate filter plist (same basename)
        flt = b'{ Filter = { Bundles = ( "com.google.ios.youtube" ); }; }'
        z.writestr('Payload/YouTube.app/Frameworks/YTEQ.plist', flt)
    print(f"OK -> {dst}")
    print("Next: Sideloadly -> select this IPA -> Advanced -> Tweak Injection auto-picks Frameworks/*.dylib -> Install")
    print("Open YouTube -> Settings -> EQ (top-right) -> Enable ON, set Preamp, adjust 10 bands.")

if __name__ == '__main__':
    main()
