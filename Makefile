# YTEQ — plain-dylib build.
#
# Deliberately not a Theos tweak. VolumeBoostYT.dylib has no Substrate/ElleKit linkage:
# it hooks with the Objective-C runtime directly, so Sideloadly's "inject dylib" is enough
# to load it. A Theos tweak would need %hook (i.e. Substrate) at runtime, which a sideloaded
# IPA does not provide, so this builds the same kind of artifact VolumeBoostYT is.
#
# Output: a fat arm64 + arm64e dylib with install_name @rpath/YTEQ.dylib, plus a copy in
# .theos-style layout for the injection script.

NAME      := YTEQ
SRCDIR    := YTEQ
BUILD     := build
SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS   := 15.0
ARCHS     := arm64 arm64e

INSTALL_NAME := @rpath/$(NAME).dylib

SOURCES  := $(wildcard $(SRCDIR)/*.m)

CFLAGS := -fobjc-arc -O2 -fno-objc-arc-exceptions \
          -Wall -Wno-unused-parameter -Wno-objc-missing-property-synthesis \
          -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
          -I$(SRCDIR)

LDFLAGS := -dynamiclib -install_name $(INSTALL_NAME) \
           -Wl,-headerpad_max_install_names \
           -Wl,-rpath,@executable_path/Frameworks \
           -Wl,-rpath,@loader_path/Frameworks \
           -Wl,-rpath,/var/jb/Library/Frameworks \
           -Wl,-rpath,/var/jb/usr/lib \
           -framework Foundation -framework CoreFoundation \
           -framework UIKit -framework CoreGraphics \
           -framework AVFoundation -framework AudioToolbox \
           -framework Accelerate -framework QuartzCore

.PHONY: all clean universal arm64 arm64e

all: universal

universal:
	@mkdir -p $(BUILD)
	@for arch in $(ARCHS); do \
	    echo "  CC  $(NAME) ($(arch))"; \
	    xcrun clang -arch $$arch $(CFLAGS) $(LDFLAGS) $(SOURCES) \
	        -o $(BUILD)/$$arch/$(NAME).dylib || exit 1; \
	done
	@echo "  LD  $(NAME).dylib (universal)"
	@lipo -create $(BUILD)/arm64/$(NAME).dylib $(BUILD)/arm64e/$(NAME).dylib \
	    -output $(NAME).dylib
	@lipo -info $(NAME).dylib

arm64:
	@mkdir -p $(BUILD)/arm64
	xcrun clang -arch arm64 $(CFLAGS) $(LDFLAGS) $(SOURCES) -o $(BUILD)/arm64/$(NAME).dylib

arm64e:
	@mkdir -p $(BUILD)/arm64e
	xcrun clang -arch arm64e $(CFLAGS) $(LDFLAGS) $(SOURCES) -o $(BUILD)/arm64e/$(NAME).dylib

clean:
	rm -rf $(BUILD) $(NAME).dylib
