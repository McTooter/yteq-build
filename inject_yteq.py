#!/usr/bin/env python3
"""Insert the built YTEQ.dylib into a YouTube IPA.

Windows-safe: this is zip surgery only. Sideloadly patches LC_LOAD_DYLIB and re-signs at
install time, so nothing here has to know how code signing works.

YTEQ is a plain dylib, not a Substrate tweak (it hooks with the Objective-C runtime and a
dyld interpose, exactly like VolumeBoostYT.dylib), so no tweak framework is required and
the .plist is optional - it is only written for people who also use a tweak manager.

Usage:
    python inject_yteq.py "<path to ipa>" YTEQ.dylib [YouTube-YTEQ.ipa]
"""
import pathlib
import plistlib
import struct
import sys
import zipfile

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF


def read_fat_archs(data):
    """Return the (cputype, cpusubtype) of every slice in a Mach-O, fat or thin."""
    if len(data) < 8:
        return []
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == FAT_MAGIC:
        n = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(n):
            cputype, cpusubtype = struct.unpack_from(">ii", data, 8 + i * 20)
            out.append((cputype & 0xFFFFFFFF, cpusubtype & 0xFFFFFFFF))
        return out
    if struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        cputype, cpusubtype = struct.unpack_from("<ii", data, 4)
        return [(cputype & 0xFFFFFFFF, cpusubtype & 0xFFFFFFFF)]
    return []


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)

    src = pathlib.Path(sys.argv[1])
    dylib = pathlib.Path(sys.argv[2])
    dst = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else src.parent / "YouTube-YTEQ.ipa"

    assert src.exists(), f"IPA not found: {src}"
    assert dylib.exists(), f"YTEQ.dylib not found: {dylib} -- run the GitHub Action 'Build YTEQ' first"

    payload = dylib.read_bytes()
    assert len(payload) > 20000, f"dylib is only {len(payload)} bytes, the build probably failed"

    archs = read_fat_archs(payload)
    if not archs:
        print("WARN: could not read Mach-O headers, skipping architecture check")
    else:
        names = []
        for cputype, cpusubtype in archs:
            if cputype != 0x0100000C:
                names.append(f"unexpected cputype {cputype:#x}")
            elif cpusubtype == 0x80000002:
                names.append("arm64e")
            elif cpusubtype == 0:
                names.append("arm64")
            else:
                names.append(f"arm64 sub {cpusubtype:#x}")
        # A simulator (x86_64/hypervisor) slice would never load on a device.
        bad = [n for n in names if "arm" not in n]
        assert not bad, f"dylib has non-device slices: {', '.join(bad)}"
        print(f"dylib architectures: {', '.join(names)}")

    shutil_target = dst
    shutil_target.write_bytes(src.read_bytes())

    with zipfile.ZipFile(dst, "a", zipfile.ZIP_DEFLATED) as z:
        try:
            info = z.read("Payload/YouTube.app/Info.plist")
            pl = plistlib.loads(info)
            print(f"Bundle: {pl.get('CFBundleIdentifier')} "
                  f"v{pl.get('CFBundleShortVersionString')} "
                  f"minOS {pl.get('MinimumOSVersion')}")
            assert pl.get("CFBundleIdentifier") == "com.google.ios.youtube", \
                "that does not look like a YouTube IPA"
        except KeyError:
            print("WARN: Info.plist not found, continuing")

        arc = "Payload/YouTube.app/Frameworks/YTEQ.dylib"
        if arc in z.namelist():
            print(f"replacing existing {arc}")
        print(f"Injecting {arc} ({len(payload)} bytes)")
        z.writestr(arc, payload)

        # Only for Substrate-style loaders. Sideloadly's dylib injection does not read it.
        z.writestr("Payload/YouTube.app/Frameworks/YTEQ.plist",
                   b'{ Filter = { Bundles = ( "com.google.ios.youtube" ); }; }')

    print(f"OK -> {dst}")
    print()
    print("Sideloadly:")
    print("  1. Connect the iPhone, select this IPA")
    print("  2. Advanced Options -> enable 'Inject dylib' (Tweak Injection)")
    print("     Sideloadly picks up Frameworks/*.dylib automatically")
    print("  3. Sideload with your Apple ID")
    print()
    print("In the app:")
    print("  Settings / Account -> an 'EQ' button appears in the nav bar (or an")
    print("  'Enable Equalizer' switch inside the settings list)")
    print("  Turn it on, set the preamp, then drag handles on the graph.")
    print("  The status line under the power switch tells you whether audio is")
    print("  actually reaching the DSP.")


if __name__ == "__main__":
    main()
