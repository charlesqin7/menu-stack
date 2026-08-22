TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VerticalMenuPrefs

VerticalMenuPrefs_FILES = VLMRootListController.m
VerticalMenuPrefs_FRAMEWORKS = UIKit
VerticalMenuPrefs_PRIVATE_FRAMEWORKS = Preferences
VerticalMenuPrefs_INSTALL_PATH = /Library/PreferenceBundles
VerticalMenuPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
