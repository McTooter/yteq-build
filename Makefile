ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTEQ

YTEQ_FILES = YTEQ/Tweak.x YTEQ/YTEQAudioEngine.m YTEQ/YTEQSettingsViewController.m
YTEQ_FRAMEWORKS = AVFoundation AudioToolbox Accelerate
YTEQ_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
