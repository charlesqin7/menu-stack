include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VerticalMenuPrefs

VerticalMenuPrefs_FILES = VLMRootListController.m
VerticalMenuPrefs_FRAMEWORKS = UIKit
VerticalMenuPrefs_PRIVATE_FRAMEWORKS = Preferences
VerticalMenuPrefs_INSTALL_PATH = /Library/PreferenceBundles
VerticalMenuPrefs_CFLAGS = -fobjc-arc
# Xcode public SDKs omit Preferences.framework; resolve PSListController on-device.
VerticalMenuPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
